USE AdventureWorks2022;
GO

/*==========================================================
  0) Create schema if missing
==========================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'Sim')
    EXEC('CREATE SCHEMA Sim AUTHORIZATION dbo;');
GO

/*==========================================================
  1) Drop existing Sim objects 
==========================================================*/
IF OBJECT_ID(N'Sim.SalesOrderLine', 'U') IS NOT NULL DROP TABLE Sim.SalesOrderLine;
IF OBJECT_ID(N'Sim.SalesOrder',     'U') IS NOT NULL DROP TABLE Sim.SalesOrder;
IF OBJECT_ID(N'Sim.Customer',        'U') IS NOT NULL DROP TABLE Sim.Customer;
IF OBJECT_ID(N'Sim.Product',         'U') IS NOT NULL DROP TABLE Sim.Product;
GO

/*==========================================================
  2) Sim.Customer = clone of Sales.Customer (structure + data)
     + PK(CustomerID) + FK back to Sales.Customer(CustomerID)
==========================================================*/
SELECT *
INTO Sim.Customer
FROM Sales.Customer;
GO

ALTER TABLE Sim.Customer
  ADD CONSTRAINT PK_Sim_Customer PRIMARY KEY CLUSTERED (CustomerID);

ALTER TABLE Sim.Customer
  ADD CONSTRAINT FK_SimCustomer_To_SalesCustomer
      FOREIGN KEY (CustomerID) REFERENCES Sales.Customer(CustomerID);
GO

/*==========================================================
  3) Sim.Product = clone of Production.Product (structure + data)
     + PK(ProductID) + FK back to Production.Product(ProductID)
==========================================================*/
SELECT *
INTO Sim.Product
FROM Production.Product;
GO

ALTER TABLE Sim.Product
  ADD CONSTRAINT PK_Sim_Product PRIMARY KEY CLUSTERED (ProductID);

ALTER TABLE Sim.Product
  ADD CONSTRAINT FK_SimProduct_To_ProdProduct
      FOREIGN KEY (ProductID) REFERENCES Production.Product(ProductID);
GO

/*==========================================================
  4) Sim.SalesOrder per mapping (columns, defaults, checks)
==========================================================*/
CREATE TABLE Sim.SalesOrder
(
    SalesOrderID  INT           NOT NULL,  -- PK (copy from source)
    CustomerID    INT           NOT NULL,  -- FK -> Sim.Customer
    OrderDate     DATETIME2     NOT NULL,
    Channel       NVARCHAR(8)   NOT NULL CONSTRAINT DF_SimSO_Channel DEFAULT(N'AWD'),
    [Status]      TINYINT       NULL,
    StatusDesc    NVARCHAR(20)  NULL,
    TerritoryID   INT           NULL,
    TaxRegion     NVARCHAR(4)   NULL,
    SubTotal      DECIMAL(19,4) NULL,
    TaxAmt        DECIMAL(19,4) NULL,
    Freight       DECIMAL(19,4) NULL,
    PromoCode     NVARCHAR(32)  NULL,
    PromoRate     DECIMAL(4,3)  NOT NULL CONSTRAINT DF_SimSO_PromoRate DEFAULT(0.000),
    TotalDue      DECIMAL(19,4) NOT NULL,
    CreatedAt     DATETIME2     NOT NULL CONSTRAINT DF_SimSO_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt     DATETIME2     NOT NULL CONSTRAINT DF_SimSO_UpdatedAt DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT PK_Sim_SalesOrder PRIMARY KEY CLUSTERED (SalesOrderID),
    CONSTRAINT FK_SimSO_Customer FOREIGN KEY (CustomerID) REFERENCES Sim.Customer(CustomerID),
    CONSTRAINT CK_SimSO_PromoRate CHECK (PromoRate BETWEEN 0.000 AND 0.500)
);
GO

/*==========================================================
  5) Sim.SalesOrderLine per mapping (columns, defaults, checks)
==========================================================*/
CREATE TABLE Sim.SalesOrderLine
(
    SalesOrderID  INT           NOT NULL,  -- FK -> Sim.SalesOrder
    LineNumber    INT           NOT NULL,  -- 1..N per order
    ProductID     INT           NOT NULL,  -- FK -> Sim.Product
    Quantity      INT           NOT NULL,
    UnitPrice     DECIMAL(19,4) NOT NULL,
    DiscountRate  DECIMAL(4,3)  NOT NULL CONSTRAINT DF_SimSOL_Discount DEFAULT(0.000),
    PromoCode     NVARCHAR(32)  NULL,
    CreatedAt     DATETIME2     NOT NULL CONSTRAINT DF_SimSOL_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt     DATETIME2     NOT NULL CONSTRAINT DF_SimSOL_UpdatedAt DEFAULT (SYSUTCDATETIME()),
    LineAmount    AS (Quantity * UnitPrice * (1 - DiscountRate)) PERSISTED,

    CONSTRAINT PK_Sim_SalesOrderLine PRIMARY KEY CLUSTERED (SalesOrderID, LineNumber),
    CONSTRAINT FK_SimSOL_SalesOrder  FOREIGN KEY (SalesOrderID) REFERENCES Sim.SalesOrder(SalesOrderID),
    CONSTRAINT FK_SimSOL_Product     FOREIGN KEY (ProductID)    REFERENCES Sim.Product(ProductID),
    CONSTRAINT CK_SimSOL_Qty         CHECK (Quantity > 0),
    CONSTRAINT CK_SimSOL_Price       CHECK (UnitPrice >= 0.01),
    CONSTRAINT CK_SimSOL_Discount    CHECK (DiscountRate BETWEEN 0.000 AND 0.500)
);
GO

/*==========================================================
  6) LOAD Sim.SalesOrder with required transformations
     - Channel = 'AWD' if OnlineOrderFlag=1 else 'B2B'
     - StatusDesc from Status
     - TaxRegion from ShipTo StateProvinceCode; fallback to Territory Group (first 4)
     - PromoCode = dominant offer (by full amount) short code
     - PromoRate = weighted avg discount (capped 0.500)
     - TotalDue  = SUM(OrderQty*UnitPrice*(1-Discount)) across lines
==========================================================*/
;WITH LineFacts AS (
    SELECT
        d.SalesOrderID,
        LineAmountFull = CAST(d.OrderQty * d.UnitPrice AS DECIMAL(19,4)),
        DiscRateCapped = CAST(CASE WHEN d.UnitPriceDiscount > 0.500 THEN 0.500 ELSE d.UnitPriceDiscount END AS DECIMAL(4,3)),
        LineAmountNet  = CAST(d.OrderQty * d.UnitPrice * (1 - CASE WHEN d.UnitPriceDiscount > 0.500 THEN 0.500 ELSE d.UnitPriceDiscount END) AS DECIMAL(19,4)),
        PromoCodeShort = CAST(
            LEFT(
                UPPER(REPLACE(CONVERT(nvarchar(64), ISNULL(so.Category,'')) + N'-' + CONVERT(nvarchar(64), ISNULL(so.[Type],'')), N' ', N'')),
                32
            ) AS NVARCHAR(32)
        )
    FROM Sales.SalesOrderDetail d
    LEFT JOIN Sales.SpecialOffer so
           ON so.SpecialOfferID = d.SpecialOfferID
),
Agg AS (
    SELECT
        lf.SalesOrderID,
        PromoRateRaw = NULLIF(SUM(lf.LineAmountFull * lf.DiscRateCapped), 0) / NULLIF(SUM(lf.LineAmountFull), 0),
        TotalDue     = SUM(lf.LineAmountNet)
    FROM LineFacts lf
    GROUP BY lf.SalesOrderID
),
DominantPromo AS (
    SELECT SalesOrderID, PromoCodeShort,
           rn = ROW_NUMBER() OVER (PARTITION BY SalesOrderID ORDER BY SUM(LineAmountFull) DESC)
    FROM LineFacts
    GROUP BY SalesOrderID, PromoCodeShort
)
INSERT INTO Sim.SalesOrder
(
    SalesOrderID, CustomerID, OrderDate, Channel, [Status], StatusDesc,
    TerritoryID, TaxRegion, SubTotal, TaxAmt, Freight, PromoCode, PromoRate,
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
    COALESCE(sp.StateProvinceCode, LEFT(t.[Group], 4)) AS TaxRegion,
    h.SubTotal,
    h.TaxAmt,
    h.Freight,
    dp.PromoCodeShort,
    CAST(CASE WHEN ag.PromoRateRaw IS NULL THEN 0.000
              WHEN ag.PromoRateRaw > 0.500 THEN 0.500
              ELSE ag.PromoRateRaw END AS DECIMAL(4,3)) AS PromoRate,
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
       ON t.TerritoryID = h.TerritoryID;
GO

/*==========================================================
  7) LOAD Sim.SalesOrderLine with required transformations
     - LineNumber = ROW_NUMBER() by SalesOrderDetailID per order
     - DiscountRate capped at 0.500
     - PromoCode derived from SpecialOffer (short code)
==========================================================*/
;WITH Numbered AS (
    SELECT
        d.SalesOrderID,
        LineNumber = ROW_NUMBER() OVER (PARTITION BY d.SalesOrderID ORDER BY d.SalesOrderDetailID),
        d.ProductID,
        Quantity   = d.OrderQty,
        UnitPrice  = d.UnitPrice,
        DiscountRate = CAST(CASE WHEN d.UnitPriceDiscount > 0.500 THEN 0.500 ELSE d.UnitPriceDiscount END AS DECIMAL(4,3)),
        PromoCode = CAST(
            LEFT(
                UPPER(REPLACE(CONVERT(nvarchar(64), ISNULL(so.Category,'')) + N'-' + CONVERT(nvarchar(64), ISNULL(so.[Type],'')), N' ', N'')),
                32
            ) AS NVARCHAR(32)
        )
    FROM Sales.SalesOrderDetail d
    LEFT JOIN Sales.SpecialOffer so
           ON so.SpecialOfferID = d.SpecialOfferID
)
INSERT INTO Sim.SalesOrderLine
    (SalesOrderID, LineNumber, ProductID, Quantity, UnitPrice, DiscountRate, PromoCode)
SELECT
    n.SalesOrderID,
    n.LineNumber,
    n.ProductID,
    n.Quantity,
    n.UnitPrice,
    n.DiscountRate,
    NULLIF(n.PromoCode, N'')
FROM Numbered n
JOIN Sim.SalesOrder so ON so.SalesOrderID = n.SalesOrderID
JOIN Sim.Product    pr ON pr.ProductID    = n.ProductID;
GO

/*==========================================================
  8) Extra CHECK constraints (hardening)
==========================================================*/
-- Limit Channel to known codes
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_SimSO_Channel')
ALTER TABLE Sim.SalesOrder WITH CHECK
ADD CONSTRAINT CK_SimSO_Channel CHECK (Channel IN (N'AWD', N'B2B'));

-- Status in 1..5 (nullable allowed)
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_SimSO_Status')
ALTER TABLE Sim.SalesOrder WITH CHECK
ADD CONSTRAINT CK_SimSO_Status CHECK ([Status] IS NULL OR [Status] BETWEEN 1 AND 5);

-- TaxRegion length when present (2..4)
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_SimSO_TaxRegionLen')
ALTER TABLE Sim.SalesOrder WITH CHECK
ADD CONSTRAINT CK_SimSO_TaxRegionLen CHECK (TaxRegion IS NULL OR (LEN(TaxRegion) BETWEEN 2 AND 4));

-- Non-negative money fields; TotalDue >= 0
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_SimSO_NonNeg')
ALTER TABLE Sim.SalesOrder WITH CHECK
ADD CONSTRAINT CK_SimSO_NonNeg CHECK (
    (SubTotal IS NULL OR SubTotal >= 0) AND
    (TaxAmt   IS NULL OR TaxAmt   >= 0) AND
    (Freight  IS NULL OR Freight  >= 0) AND
    (TotalDue >= 0)
);

-- Monotonic timestamps
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_SimSO_Timestamps')
ALTER TABLE Sim.SalesOrder WITH CHECK
ADD CONSTRAINT CK_SimSO_Timestamps CHECK (UpdatedAt >= CreatedAt);

-- SalesOrderLine: LineNumber >= 1
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_SimSOL_LineNumberPos')
ALTER TABLE Sim.SalesOrderLine WITH CHECK
ADD CONSTRAINT CK_SimSOL_LineNumberPos CHECK (LineNumber >= 1);

-- SalesOrderLine: LineAmount >= 0 (belt & suspenders)
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_SimSOL_LineAmountNonNeg')
ALTER TABLE Sim.SalesOrderLine WITH CHECK
ADD CONSTRAINT CK_SimSOL_LineAmountNonNeg CHECK (LineAmount >= 0);

-- Optional: Promo code hygiene (no spaces)
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_SimSOL_PromoCode_NoSpaces')
ALTER TABLE Sim.SalesOrderLine WITH CHECK
ADD CONSTRAINT CK_SimSOL_PromoCode_NoSpaces CHECK (PromoCode IS NULL OR PromoCode NOT LIKE N'% %');
GO

/*==========================================================
  9) Helpful indexes
==========================================================*/
CREATE INDEX IX_SimSO_Customer_OrderDate ON Sim.SalesOrder(CustomerID, OrderDate);
CREATE INDEX IX_SimSO_Territory          ON Sim.SalesOrder(TerritoryID);
CREATE INDEX IX_SimSO_Promo              ON Sim.SalesOrder(PromoCode, PromoRate);

CREATE INDEX IX_SimSOL_Order             ON Sim.SalesOrderLine(SalesOrderID, LineNumber);
CREATE INDEX IX_SimSOL_Product           ON Sim.SalesOrderLine(ProductID);
GO

/*==========================================================
  10) (Optional) Quick validators  uncomment to run
==========================================================*/
-- -- Header vs lines recompute should match (0.01):
 SELECT TOP (20)
   so.SalesOrderID,
   so.TotalDue            AS HeaderTotalDue,
   SUM(sol.LineAmount)    AS LinesTotalDue,
   (so.TotalDue - SUM(sol.LineAmount)) AS Delta
 FROM Sim.SalesOrder so
 JOIN Sim.SalesOrderLine sol ON sol.SalesOrderID = so.SalesOrderID
 GROUP BY so.SalesOrderID, so.TotalDue
 HAVING ABS(so.TotalDue - SUM(sol.LineAmount)) > 0.01
 ORDER BY ABS(so.TotalDue - SUM(sol.LineAmount)) DESC;

-- -- Basic row counts:
-- SELECT (SELECT COUNT(*) FROM Sim.Customer)      AS SimCustomerCount,
--        (SELECT COUNT(*) FROM Sim.Product)       AS SimProductCount,
--        (SELECT COUNT(*) FROM Sim.SalesOrder)    AS SimSalesOrderCount,
--        (SELECT COUNT(*) FROM Sim.SalesOrderLine)AS SimSalesOrderLineCount;
