/*====================================================================
  COURSE: SQL Server Development
  NAME:SUHANI MEHTA
  STUDENT ID: N01750525
  SIMULATION 3: Keys, Constraints & Joins in the AdventureWorks DB
  DATABASE: AdventureWorks2025

====================================================================*/
DECLARE @DateWindowStart DATE = '2025-02-11';  
DECLARE @DateWindowEnd   DATE = '2025-02-28';  
DECLARE @OnlineFlagFilter BIT = 1;            



;WITH CustStaging AS (
    SELECT
        c.CustomerID,
        c.PersonID,
        c.StoreID,
        c.TerritoryID,
        c.AccountNumber,
        AWDFlag = CASE WHEN EXISTS(
            SELECT 1 FROM Sales.SalesOrderHeader h 
            WHERE h.CustomerID = c.CustomerID
              AND (@OnlineFlagFilter IS NULL OR h.OnlineOrderFlag = @OnlineFlagFilter)
              AND h.OrderDate BETWEEN @DateWindowStart AND @DateWindowEnd
        ) THEN 1 ELSE 0 END
    FROM Sales.Customer c
)
INSERT INTO Sim.Customer
(
    CustomerID, PersonID, StoreID, TerritoryID, AccountNumber, AWDFlag
)
SELECT *
FROM CustStaging;
GO

--Load Sim.Product

;WITH ProductStaging AS (
    SELECT
        p.ProductID,
        p.Name,
        p.ProductNumber,
        p.Color,
        p.StandardCost,
        p.ListPrice,
        p.Size,
        p.Weight,
        p.CategoryID,
        p.SubcategoryID,
        p.DiscontinuedFlag,
        AWDEligible = CASE WHEN p.DiscontinuedFlag = 0 THEN 1 ELSE 0 END
    FROM Production.Product p
)
INSERT INTO Sim.Product
(
    ProductID, Name, ProductNumber, Color, StandardCost, ListPrice,
    Size, Weight, CategoryID, SubcategoryID, DiscontinuedFlag, AWDEligible
)
SELECT *
FROM ProductStaging;
GO


--Load Sim.SalesOrderLine

;WITH LineFacts AS (
    SELECT
        d.SalesOrderID,
        d.SalesOrderDetailID,
        d.ProductID,
        d.OrderQty,
        d.UnitPrice,
        d.UnitPriceDiscount,
        LineAmountFull = CAST(d.OrderQty * d.UnitPrice AS DECIMAL(19,4)),
        DiscRateCapped = CAST(
            CASE WHEN d.UnitPriceDiscount > 0.500 THEN 0.500 ELSE d.UnitPriceDiscount END
            AS DECIMAL(4,3)
        ),
        LineAmountNet = CAST(d.OrderQty * d.UnitPrice * (1 - 
            CASE WHEN d.UnitPriceDiscount > 0.500 THEN 0.500 ELSE d.UnitPriceDiscount END
        ) AS DECIMAL(19,4))
    FROM Sales.SalesOrderDetail d
    INNER JOIN Sales.SalesOrderHeader h
        ON h.SalesOrderID = d.SalesOrderID
    WHERE h.OrderDate BETWEEN @DateWindowStart AND @DateWindowEnd
      AND (@OnlineFlagFilter IS NULL OR h.OnlineOrderFlag = @OnlineFlagFilter)
)
INSERT INTO Sim.SalesOrderLine
(
    SalesOrderDetailID,
    SalesOrderID,
    ProductID,
    OrderQty,
    UnitPrice,
    UnitPriceDiscount,
    LineAmountFull,
    DiscRateCapped,
    LineAmountNet
)
SELECT *
FROM LineFacts;
GO


--Load Sim.SalesOrder

;WITH Agg AS (
    SELECT
        d.SalesOrderID,
        PromoRateRaw = NULLIF(SUM(d.LineAmountFull * d.DiscRateCapped),0)
                     / NULLIF(SUM(d.LineAmountFull),0),
        TotalDue = SUM(d.LineAmountNet)
    FROM Sim.SalesOrderLine d
    GROUP BY d.SalesOrderID
),
DominantPromo AS (
    SELECT SalesOrderID, ProductID,
           rn = ROW_NUMBER() OVER (PARTITION BY SalesOrderID ORDER BY SUM(LineAmountFull) DESC)
    FROM Sim.SalesOrderLine
    GROUP BY SalesOrderID, ProductID
)
INSERT INTO Sim.SalesOrder
(
    SalesOrderID,
    CustomerID,
    OrderDate,
    Channel,
    [Status],
    StatusDesc,
    TerritoryID,
    TaxRegion,
    SubTotal,
    TaxAmt,
    Freight,
    PromoCode,
    PromoRate,
    TotalDue
)
SELECT
    h.SalesOrderID,
    h.CustomerID,
    h.OrderDate,
    CASE WHEN h.OnlineOrderFlag = 1 THEN N'AWD' ELSE N'B2B' END AS Channel,
    h.[Status],
    CASE h.[Status]
        WHEN 1 THEN N'InProcess'
        WHEN 2 THEN N'Approved'
        WHEN 3 THEN N'Backordered'
        WHEN 4 THEN N'Rejected'
        WHEN 5 THEN N'Shipped'
        ELSE N'Unknown'
    END AS StatusDesc,
    h.TerritoryID,
    COALESCE(sp.StateProvinceCode, LEFT(t.[Group],4)) AS TaxRegion,
    h.SubTotal,
    h.TaxAmt,
    h.Freight,
    dp.ProductID, 
    CAST(
        CASE 
            WHEN ag.PromoRateRaw IS NULL THEN 0.000
            WHEN ag.PromoRateRaw > 0.500 THEN 0.500
            ELSE ag.PromoRateRaw
        END AS DECIMAL(4,3)
    ) AS PromoRate,
    ag.TotalDue
FROM Sales.SalesOrderHeader h
LEFT JOIN Agg ag
       ON ag.SalesOrderID = h.SalesOrderID
LEFT JOIN DominantPromo dp
       ON dp.SalesOrderID = h.SalesOrderID AND dp.rn = 1
LEFT JOIN Person.[Address] a
       ON a.AddressID = h.ShipToAddressID
LEFT JOIN Person.StateProvince sp
       ON sp.StateProvinceID = a.StateProvinceID
LEFT JOIN Sales.SalesTerritory t
       ON t.TerritoryID = h.TerritoryID
WHERE h.OrderDate BETWEEN @DateWindowStart AND @DateWindowEnd
  AND (@OnlineFlagFilter IS NULL OR h.OnlineOrderFlag = @OnlineFlagFilter);
GO

