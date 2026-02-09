USE AdventureWorks2022;
GO

CREATE OR ALTER FUNCTION dbo.ufn_R2S_ReadyToShip
(
    @Last24h           bit,             -- 0 = Today, 1 = last 24h
    @Region            nvarchar(100) = NULL,
    @Promo             nvarchar(50)  = NULL,
    @PriorityThreshold int           = NULL,
    @AsOf              datetime2     = NULL         -- pass NULL to use SYSDATETIME()
)
RETURNS TABLE
AS
RETURN
WITH ValidLines AS (
    SELECT
        d.SalesOrderID,
        d.SalesOrderDetailID,
        d.LineTotal
    FROM Sales.SalesOrderDetail AS d
    INNER JOIN Production.Product AS p
        ON p.ProductID = d.ProductID
    WHERE d.OrderQty  > 0
      AND d.UnitPrice > 0
      AND (
            p.SellEndDate IS NULL
         OR p.SellEndDate > COALESCE(@AsOf, SYSDATETIME())
      )
),
OrderLinesAgg AS (
    SELECT
        vl.SalesOrderID,
        LinesCount    = COUNT(*),
        LinesSubtotal = SUM(vl.LineTotal)
    FROM ValidLines vl
    GROUP BY vl.SalesOrderID
)
SELECT
    h.SalesOrderID                                                AS OrderID,
    h.OrderDate                                                   AS OrderDateTime,
    c.CustomerID,
    CustomerName = COALESCE(s.Name, CONCAT(p.FirstName, N' ', p.LastName)),
    Region       = t.Name,
    ola.LinesCount,
    h.TotalDue,
    ExceptionsFlag = N'No',
    PriorityScore  = CAST(DATEDIFF(hour, h.OrderDate, COALESCE(@AsOf, SYSDATETIME())) AS int),
    PromoCodes = (
        SELECT STRING_AGG(x.PromoCode, ',')
        FROM (
            SELECT DISTINCT
                   COALESCE(
                       LEFT(REPLACE(so.[Description],' ',''),12),
                       CONCAT('SO', CONVERT(varchar(10), d2.SpecialOfferID))
                   ) AS PromoCode
            FROM Sales.SalesOrderDetail d2
            LEFT JOIN Sales.SpecialOffer so
              ON so.SpecialOfferID = d2.SpecialOfferID
            WHERE d2.SalesOrderID = h.SalesOrderID
        ) AS x
    )
FROM Sales.SalesOrderHeader AS h
INNER JOIN OrderLinesAgg AS ola
    ON ola.SalesOrderID = h.SalesOrderID
INNER JOIN Sales.Customer AS c
    ON c.CustomerID = h.CustomerID
LEFT JOIN Person.Person AS p
    ON p.BusinessEntityID = c.PersonID
LEFT JOIN Sales.Store AS s
    ON s.BusinessEntityID = c.StoreID
LEFT JOIN Sales.SalesTerritory AS t
    ON t.TerritoryID = c.TerritoryID
WHERE
    COALESCE(s.Name, CONCAT(p.FirstName, N' ', p.LastName)) IS NOT NULL
    AND h.OrderDate >= CASE
                        WHEN @Last24h = 1 THEN DATEADD(hour, -24, COALESCE(@AsOf, SYSDATETIME()))
                        ELSE CONVERT(date, COALESCE(@AsOf, SYSDATETIME()))
                       END
    AND h.OrderDate <  CASE
                        WHEN @Last24h = 1 THEN COALESCE(@AsOf, SYSDATETIME())
                        ELSE DATEADD(day, 1, CONVERT(date, COALESCE(@AsOf, SYSDATETIME())))
                       END
    AND ABS(h.SubTotal - ola.LinesSubtotal) <= 0.01
    AND (@Region IS NULL OR t.Name = @Region)
    AND (
        @Promo IS NULL
        OR EXISTS (
            SELECT 1
            FROM (
                SELECT DISTINCT
                       COALESCE(
                           LEFT(REPLACE(so2.[Description],' ',''),12),
                           CONCAT('SO', CONVERT(varchar(10), d3.SpecialOfferID))
                       ) AS PromoCode
                FROM Sales.SalesOrderDetail d3
                LEFT JOIN Sales.SpecialOffer so2
                  ON so2.SpecialOfferID = d3.SpecialOfferID
                WHERE d3.SalesOrderID = h.SalesOrderID
            ) AS px
            WHERE px.PromoCode LIKE '%' + @Promo + '%'
        )
    )
    AND (
        @PriorityThreshold IS NULL
        OR DATEDIFF(hour, h.OrderDate, COALESCE(@AsOf, SYSDATETIME())) >= @PriorityThreshold
    );
GO

-- Today
SELECT * 
FROM dbo.ufn_R2S_ReadyToShip(0, NULL, NULL, NULL, NULL);

--Last 24h + Region filter
SELECT * 
FROM dbo.ufn_R2S_ReadyToShip(1, N'Northwest', NULL, NULL, NULL);

--Promo contains “BLACK”, Priority ≥ 12h, fixed timestam
SELECT * 
FROM dbo.ufn_R2S_ReadyToShip(0, NULL, N'BLACK', 12, '2025-09-28T10:00:00');

--Specific Date
SELECT *
FROM dbo.ufn_R2S_ReadyToShip(
    1,              -- @Last24h: 0 = "Today" window around @AsOf's date
    NULL,           -- @Region
    NULL,           -- @Promo
    NULL,           -- @PriorityThreshold
    '2014-06-30T12:00:00'  -- @AsOf within your data range
);

