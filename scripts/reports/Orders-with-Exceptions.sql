USE AdventureWorks2022;
GO

CREATE OR ALTER PROCEDURE dbo.usp_OWE_OrdersWithExceptions_Out
    @ExceptionType         nvarchar(40)  = NULL,   -- 'MissingCustomer' | 'NoLines' | 'NegativePrice' | 'DiscontinuedSKU'
    @Region                nvarchar(100) = NULL,   -- SalesTerritory.Name
    @Promo                 nvarchar(50)  = NULL,   -- substring in derived PromoCode
    @AsOf                  datetime2     = NULL,   -- NULL => SYSDATETIME()
    @Rows                  int           = NULL OUTPUT,
    @RevenueAtRiskTotal    decimal(19,4) = NULL OUTPUT,
    @ReportJson            nvarchar(max) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @now   datetime2 = COALESCE(@AsOf, SYSDATETIME());
    DECLARE @start datetime2 = DATEADD(hour, -48, @now);
    DECLARE @end   datetime2 = @now;

    /* ===== Main grid result ===== */
    WITH Orders48h AS (
        SELECT h.SalesOrderID, h.CustomerID, h.OrderDate
        FROM Sales.SalesOrderHeader h
        WHERE h.OrderDate >= @start AND h.OrderDate < @end
    ),
    Cust AS (
        SELECT c.CustomerID,
               CustomerName = COALESCE(s.Name, p.FirstName + N' ' + p.LastName),
               Region = t.Name
        FROM Sales.Customer c
        LEFT JOIN Person.Person p ON p.BusinessEntityID = c.PersonID
        LEFT JOIN Sales.Store   s ON s.BusinessEntityID = c.StoreID
        LEFT JOIN Sales.SalesTerritory t ON t.TerritoryID = c.TerritoryID
    ),
    Lines AS (
        SELECT d.SalesOrderID,
               d.SalesOrderDetailID,
               d.LineTotal,
               d.UnitPrice,
               IsNegativePrice = CASE WHEN d.UnitPrice <= 0 THEN 1 ELSE 0 END,
               IsDiscontinued  = CASE WHEN p.SellEndDate IS NOT NULL AND p.SellEndDate <= @now THEN 1 ELSE 0 END,
               PromoCode = COALESCE(NULLIF(LEFT(REPLACE(so.[Description],' ',''),12), ''),
                                    CONCAT('SO', CONVERT(varchar(10), d.SpecialOfferID)))
        FROM Sales.SalesOrderDetail d
        JOIN Orders48h o ON o.SalesOrderID = d.SalesOrderID
        JOIN Production.Product p ON p.ProductID = d.ProductID
        LEFT JOIN Sales.SpecialOffer so ON so.SpecialOfferID = d.SpecialOfferID
    ),
    LineAgg AS (
        SELECT SalesOrderID, LinesCount = COUNT(*), Revenue = SUM(LineTotal)
        FROM Lines GROUP BY SalesOrderID
    ),
    Report AS (
        /* MissingCustomer */
        SELECT o.SalesOrderID AS OrderID, N'MissingCustomer' AS ExceptionType,
               COALESCE(a.LinesCount,0) AS CountAffectedLines,
               COALESCE(a.Revenue,0.0)  AS RevenueAtRisk
        FROM Orders48h o
        LEFT JOIN Cust cu ON cu.CustomerID = o.CustomerID
        LEFT JOIN LineAgg a ON a.SalesOrderID = o.SalesOrderID
        WHERE cu.CustomerName IS NULL
          AND (@Region IS NULL OR cu.Region = @Region)
          AND (@Promo IS NULL OR EXISTS (
                SELECT 1 FROM Lines l
                WHERE l.SalesOrderID = o.SalesOrderID
                  AND l.PromoCode LIKE '%' + @Promo + '%'
          ))

        UNION ALL

        /* NoLines */
        SELECT o.SalesOrderID, N'NoLines', 0, CAST(0.0 AS decimal(19,4))
        FROM Orders48h o
        LEFT JOIN Sales.SalesOrderDetail d ON d.SalesOrderID = o.SalesOrderID
        LEFT JOIN Sales.SalesOrderHeader  h ON h.SalesOrderID = o.SalesOrderID
        LEFT JOIN Cust cu ON cu.CustomerID = h.CustomerID
        WHERE d.SalesOrderID IS NULL
          AND (@Region IS NULL OR cu.Region = @Region)
          AND (@Promo IS NULL)

        UNION ALL

        /* NegativePrice */
        SELECT l.SalesOrderID, N'NegativePrice', COUNT(*), SUM(l.LineTotal)
        FROM Lines l
        JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = l.SalesOrderID
        JOIN Cust cu ON cu.CustomerID = h.CustomerID
        WHERE l.IsNegativePrice = 1
          AND (@Region IS NULL OR cu.Region = @Region)
          AND (@Promo  IS NULL OR l.PromoCode LIKE '%' + @Promo + '%')
        GROUP BY l.SalesOrderID

        UNION ALL

        /* DiscontinuedSKU */
        SELECT l.SalesOrderID, N'DiscontinuedSKU', COUNT(*), SUM(l.LineTotal)
        FROM Lines l
        JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = l.SalesOrderID
        JOIN Cust cu ON cu.CustomerID = h.CustomerID
        WHERE l.IsDiscontinued = 1
          AND (@Region IS NULL OR cu.Region = @Region)
          AND (@Promo  IS NULL OR l.PromoCode LIKE '%' + @Promo + '%')
        GROUP BY l.SalesOrderID
    )
    SELECT *
    FROM Report
    WHERE (@ExceptionType IS NULL OR ExceptionType = @ExceptionType)
    ORDER BY ExceptionType, OrderID;

    /* ===== OUTPUT scalars: CTE valid for ONE statement, so use it once here ===== */
    ;WITH Orders48h AS (
        SELECT h.SalesOrderID, h.CustomerID, h.OrderDate
        FROM Sales.SalesOrderHeader h
        WHERE h.OrderDate >= @start AND h.OrderDate < @end
    ),
    Cust AS (
        SELECT c.CustomerID,
               CustomerName = COALESCE(s.Name, p.FirstName + N' ' + p.LastName),
               Region = t.Name
        FROM Sales.Customer c
        LEFT JOIN Person.Person p ON p.BusinessEntityID = c.PersonID
        LEFT JOIN Sales.Store   s ON s.BusinessEntityID = c.StoreID
        LEFT JOIN Sales.SalesTerritory t ON t.TerritoryID = c.TerritoryID
    ),
    Lines AS (
        SELECT d.SalesOrderID, d.SalesOrderDetailID, d.LineTotal, d.UnitPrice,
               IsNegativePrice = CASE WHEN d.UnitPrice <= 0 THEN 1 ELSE 0 END,
               IsDiscontinued  = CASE WHEN p.SellEndDate IS NOT NULL AND p.SellEndDate <= @now THEN 1 ELSE 0 END,
               PromoCode = COALESCE(NULLIF(LEFT(REPLACE(so.[Description],' ',''),12), ''),
                                    CONCAT('SO', CONVERT(varchar(10), d.SpecialOfferID)))
        FROM Sales.SalesOrderDetail d
        JOIN Orders48h o ON o.SalesOrderID = d.SalesOrderID
        JOIN Production.Product p ON p.ProductID = d.ProductID
        LEFT JOIN Sales.SpecialOffer so ON so.SpecialOfferID = d.SpecialOfferID
    ),
    LineAgg AS (
        SELECT SalesOrderID, LinesCount = COUNT(*), Revenue = SUM(LineTotal)
        FROM Lines GROUP BY SalesOrderID
    ),
    Report AS (
        SELECT o.SalesOrderID AS OrderID, N'MissingCustomer' AS ExceptionType,
               COALESCE(a.LinesCount,0) AS CountAffectedLines,
               COALESCE(a.Revenue,0.0)  AS RevenueAtRisk
        FROM Orders48h o
        LEFT JOIN Cust cu ON cu.CustomerID = o.CustomerID
        LEFT JOIN LineAgg a ON a.SalesOrderID = o.SalesOrderID
        WHERE cu.CustomerName IS NULL
          AND (@Region IS NULL OR cu.Region = @Region)
          AND (@Promo IS NULL OR EXISTS (
                SELECT 1 FROM Lines l
                WHERE l.SalesOrderID = o.SalesOrderID
                  AND l.PromoCode LIKE '%' + @Promo + '%'
          ))
        UNION ALL
        SELECT o.SalesOrderID, N'NoLines', 0, CAST(0.0 AS decimal(19,4))
        FROM Orders48h o
        LEFT JOIN Sales.SalesOrderDetail d ON d.SalesOrderID = o.SalesOrderID
        LEFT JOIN Sales.SalesOrderHeader  h ON h.SalesOrderID = o.SalesOrderID
        LEFT JOIN Cust cu ON cu.CustomerID = h.CustomerID
        WHERE d.SalesOrderID IS NULL
          AND (@Region IS NULL OR cu.Region = @Region)
          AND (@Promo IS NULL)
        UNION ALL
        SELECT l.SalesOrderID, N'NegativePrice', COUNT(*), SUM(l.LineTotal)
        FROM Lines l
        JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = l.SalesOrderID
        JOIN Cust cu ON cu.CustomerID = h.CustomerID
        WHERE l.IsNegativePrice = 1
          AND (@Region IS NULL OR cu.Region = @Region)
          AND (@Promo  IS NULL OR l.PromoCode LIKE '%' + @Promo + '%')
        GROUP BY l.SalesOrderID
        UNION ALL
        SELECT l.SalesOrderID, N'DiscontinuedSKU', COUNT(*), SUM(l.LineTotal)
        FROM Lines l
        JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = l.SalesOrderID
        JOIN Cust cu ON cu.CustomerID = h.CustomerID
        WHERE l.IsDiscontinued = 1
          AND (@Region IS NULL OR cu.Region = @Region)
          AND (@Promo  IS NULL OR l.PromoCode LIKE '%' + @Promo + '%')
        GROUP BY l.SalesOrderID
    )
    SELECT
        @Rows               = COUNT(*),
        @RevenueAtRiskTotal = COALESCE(SUM(RevenueAtRisk), 0.00)
    FROM Report
    WHERE (@ExceptionType IS NULL OR ExceptionType = @ExceptionType);

    /* ===== OUTPUT JSON: re-declare the CTE again for the JSON assignment ===== */
    ;WITH Orders48h AS (
        SELECT h.SalesOrderID, h.CustomerID, h.OrderDate
        FROM Sales.SalesOrderHeader h
        WHERE h.OrderDate >= @start AND h.OrderDate < @end
    ),
    Cust AS (
        SELECT c.CustomerID,
               CustomerName = COALESCE(s.Name, p.FirstName + N' ' + p.LastName),
               Region = t.Name
        FROM Sales.Customer c
        LEFT JOIN Person.Person p ON p.BusinessEntityID = c.PersonID
        LEFT JOIN Sales.Store   s ON s.BusinessEntityID = c.StoreID
        LEFT JOIN Sales.SalesTerritory t ON t.TerritoryID = c.TerritoryID
    ),
    Lines AS (
        SELECT d.SalesOrderID, d.SalesOrderDetailID, d.LineTotal, d.UnitPrice,
               IsNegativePrice = CASE WHEN d.UnitPrice <= 0 THEN 1 ELSE 0 END,
               IsDiscontinued  = CASE WHEN p.SellEndDate IS NOT NULL AND p.SellEndDate <= @now THEN 1 ELSE 0 END,
               PromoCode = COALESCE(NULLIF(LEFT(REPLACE(so.[Description],' ',''),12), ''),
                                    CONCAT('SO', CONVERT(varchar(10), d.SpecialOfferID)))
        FROM Sales.SalesOrderDetail d
        JOIN Orders48h o ON o.SalesOrderID = d.SalesOrderID
        JOIN Production.Product p ON p.ProductID = d.ProductID
        LEFT JOIN Sales.SpecialOffer so ON so.SpecialOfferID = d.SpecialOfferID
    ),
    LineAgg AS (
        SELECT SalesOrderID, LinesCount = COUNT(*), Revenue = SUM(LineTotal)
        FROM Lines GROUP BY SalesOrderID
    ),
    Report AS (
        SELECT o.SalesOrderID AS OrderID, N'MissingCustomer' AS ExceptionType,
               COALESCE(a.LinesCount,0) AS CountAffectedLines,
               COALESCE(a.Revenue,0.0)  AS RevenueAtRisk
        FROM Orders48h o
        LEFT JOIN Cust cu ON cu.CustomerID = o.CustomerID
        LEFT JOIN LineAgg a ON a.SalesOrderID = o.SalesOrderID
        WHERE cu.CustomerName IS NULL
          AND (@Region IS NULL OR cu.Region = @Region)
          AND (@Promo IS NULL OR EXISTS (
                SELECT 1 FROM Lines l
                WHERE l.SalesOrderID = o.SalesOrderID
                  AND l.PromoCode LIKE '%' + @Promo + '%'
          ))
        UNION ALL
        SELECT o.SalesOrderID, N'NoLines', 0, CAST(0.0 AS decimal(19,4))
        FROM Orders48h o
        LEFT JOIN Sales.SalesOrderDetail d ON d.SalesOrderID = o.SalesOrderID
        LEFT JOIN Sales.SalesOrderHeader  h ON h.SalesOrderID = o.SalesOrderID
        LEFT JOIN Cust cu ON cu.CustomerID = h.CustomerID
        WHERE d.SalesOrderID IS NULL
          AND (@Region IS NULL OR cu.Region = @Region)
          AND (@Promo IS NULL)
        UNION ALL
        SELECT l.SalesOrderID, N'NegativePrice', COUNT(*), SUM(l.LineTotal)
        FROM Lines l
        JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = l.SalesOrderID
        JOIN Cust cu ON cu.CustomerID = h.CustomerID
        WHERE l.IsNegativePrice = 1
          AND (@Region IS NULL OR cu.Region = @Region)
        AND (@Promo  IS NULL OR l.PromoCode LIKE '%' + @Promo + '%')
        GROUP BY l.SalesOrderID
        UNION ALL
        SELECT l.SalesOrderID, N'DiscontinuedSKU', COUNT(*), SUM(l.LineTotal)
        FROM Lines l
        JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = l.SalesOrderID
        JOIN Cust cu ON cu.CustomerID = h.CustomerID
        WHERE l.IsDiscontinued = 1
          AND (@Region IS NULL OR cu.Region = @Region)
          AND (@Promo  IS NULL OR l.PromoCode LIKE '%' + @Promo + '%')
        GROUP BY l.SalesOrderID
    )
    SELECT @ReportJson =
        (SELECT OrderID, ExceptionType, CountAffectedLines, RevenueAtRisk
         FROM Report
         WHERE (@ExceptionType IS NULL OR ExceptionType = @ExceptionType)
         ORDER BY ExceptionType, OrderID
         FOR JSON PATH, INCLUDE_NULL_VALUES);
END
GO

-- Test
DECLARE @rows int, @rev decimal(19,4), @json nvarchar(max);

EXEC dbo.usp_OWE_OrdersWithExceptions_Out
    @ExceptionType = NULL,                 -- or N'NegativePrice'
    @Region        = NULL,                 -- or N'Northwest'
    @Promo         = NULL,                 -- or N'DISC'
    @AsOf          = '2014-05-01T12:00:00',-- anchor within data range
    @Rows          = @rows OUTPUT,
    @RevenueAtRiskTotal = @rev OUTPUT,
    @ReportJson    = @json OUTPUT;         -- optional

-- Grid shows in SSMS Results automatically.
--SELECT @rows AS Rows, @rev AS RevenueAtRiskTotal;  -- quick summary
SELECT @json AS ReportJson;                     -- if you want the JSON blob


-- To confirm an output
WITH L AS (
  SELECT d.SalesOrderID, d.SalesOrderDetailID, d.LineTotal, d.UnitPrice,
         p.SellEndDate, h.OrderDate
  FROM Sales.SalesOrderDetail d
  JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID
  JOIN Production.Product p     ON p.ProductID     = d.ProductID
),
Ex AS (
  SELECT
    CAST(OrderDate AS date) AS OrderDay,
    ExceptionType =
      CASE
        WHEN NOT EXISTS (
           SELECT 1 FROM Sales.SalesOrderDetail d2 WHERE d2.SalesOrderID = l.SalesOrderID
        ) THEN 'NoLines'
        WHEN l.UnitPrice <= 0 THEN 'NegativePrice'
        WHEN l.SellEndDate IS NOT NULL AND l.SellEndDate <= l.OrderDate THEN 'DiscontinuedSKU'
      END,
    l.SalesOrderID,
    l.LineTotal
  FROM L l
)
SELECT TOP (20)
  OrderDay,
  ExceptionType,
  COUNT(DISTINCT SalesOrderID) AS Orders,
  SUM(LineTotal)               AS RevenueAtRisk
FROM Ex
WHERE ExceptionType IS NOT NULL
GROUP BY OrderDay, ExceptionType
ORDER BY OrderDay DESC, ExceptionType;

