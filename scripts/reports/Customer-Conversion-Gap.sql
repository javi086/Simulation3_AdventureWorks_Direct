USE AdventureWorks2022;
GO

/* Production AWD View: last 30 days ending at SYSDATETIME() */
CREATE OR ALTER VIEW dbo.vw_R3_NoAWDOrder_Last30d
AS
WITH Cust AS (
    SELECT
        c.CustomerID,
        CustomerName = COALESCE(s.Name, p.FirstName + N' ' + p.LastName),
        Region       = t.Name,
        Segment      = CASE WHEN c.PersonID IS NOT NULL THEN N'Consumer'
                            WHEN c.StoreID  IS NOT NULL THEN N'Store'
                            ELSE N'Unknown' END,
        c.ModifiedDate AS CustMod,
        p.ModifiedDate AS PersonMod,
        s.ModifiedDate AS StoreMod
    FROM Sales.Customer c
    LEFT JOIN Person.Person        p ON p.BusinessEntityID = c.PersonID
    LEFT JOIN Sales.Store          s ON s.BusinessEntityID = c.StoreID
    LEFT JOIN Sales.SalesTerritory t ON t.TerritoryID      = c.TerritoryID
),
WinOrders AS (
    SELECT h.CustomerID, COUNT(*) AS Cnt
    FROM Sales.SalesOrderHeader h
    WHERE h.OnlineOrderFlag = 1
      AND h.OrderDate >= DATEADD(day,-30,SYSDATETIME())
      AND h.OrderDate <  SYSDATETIME()
    GROUP BY h.CustomerID
),
LastSeen AS (
    SELECT
        c.CustomerID,
        LastSeenDate =
            (SELECT MAX(v.d) FROM (
                 SELECT MAX(h2.OrderDate) AS d
                 FROM Sales.SalesOrderHeader h2
                 WHERE h2.CustomerID = c.CustomerID
                 UNION ALL SELECT c.CustMod
                 UNION ALL SELECT c.PersonMod
                 UNION ALL SELECT c.StoreMod
            ) v)
    FROM Cust c
)
SELECT
    c.CustomerID,
    c.CustomerName,
    c.Region,
    ls.LastSeenDate,
    HasOrderFlag = N'No',
    c.Segment
FROM Cust c
LEFT JOIN WinOrders w  ON w.CustomerID = c.CustomerID
LEFT JOIN LastSeen  ls ON ls.CustomerID = c.CustomerID
WHERE COALESCE(w.Cnt,0) = 0
  AND c.CustomerName IS NOT NULL;
GO

/* Demo AWD view: last 30 days ending 2014-07-01 12:00 */
CREATE OR ALTER VIEW dbo.vw_R3_NoAWDOrder_Last30d_2014Demo
AS
WITH Params AS (
    SELECT
        AsOf  = CAST('2014-07-01T12:00:00' AS datetime2),
        Start = DATEADD(day,-30,CAST('2014-07-01T12:00:00' AS datetime2))
),
Cust AS (
    SELECT
        c.CustomerID,
        CustomerName = COALESCE(s.Name, p.FirstName + N' ' + p.LastName),
        Region       = t.Name,
        Segment      = CASE WHEN c.PersonID IS NOT NULL THEN N'Consumer'
                            WHEN c.StoreID  IS NOT NULL THEN N'Store'
                            ELSE N'Unknown' END,
        c.ModifiedDate AS CustMod,
        p.ModifiedDate AS PersonMod,
        s.ModifiedDate AS StoreMod
    FROM Sales.Customer c
    LEFT JOIN Person.Person        p ON p.BusinessEntityID = c.PersonID
    LEFT JOIN Sales.Store          s ON s.BusinessEntityID = c.StoreID
    LEFT JOIN Sales.SalesTerritory t ON t.TerritoryID      = c.TerritoryID
),
WinOrders AS (
    SELECT h.CustomerID, COUNT(*) AS Cnt
    FROM Sales.SalesOrderHeader h
    CROSS JOIN Params prm
    WHERE h.OnlineOrderFlag = 1
      AND h.OrderDate >= prm.Start
      AND h.OrderDate <  prm.AsOf
    GROUP BY h.CustomerID
),
LastSeen AS (
    SELECT
        c.CustomerID,
        LastSeenDate =
            (SELECT MAX(v.d) FROM (
                 SELECT MAX(h2.OrderDate) AS d
                 FROM Sales.SalesOrderHeader h2
                 WHERE h2.CustomerID = c.CustomerID
                 UNION ALL SELECT c.CustMod
                 UNION ALL SELECT c.PersonMod
                 UNION ALL SELECT c.StoreMod
            ) v)
    FROM Cust c
)
SELECT
    c.CustomerID,
    c.CustomerName,
    c.Region,
    ls.LastSeenDate,
    HasOrderFlag = N'No',
    c.Segment
FROM Cust c
LEFT JOIN WinOrders w  ON w.CustomerID = c.CustomerID
LEFT JOIN LastSeen  ls ON ls.CustomerID = c.CustomerID
WHERE COALESCE(w.Cnt,0) = 0
  AND c.CustomerName IS NOT NULL;
GO

--Test
-- Production View
SELECT TOP 50 * FROM dbo.vw_R3_NoAWDOrder_Last30d
ORDER BY Region, Segment, CustomerName;

-- Demo View
SELECT TOP 50 * FROM dbo.vw_R3_NoAWDOrder_Last30d_2014Demo
ORDER BY Region, Segment, CustomerName;

