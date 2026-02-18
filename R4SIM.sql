/*
R4 - Never Sold SKUs

This report tries to find products that are available to sell online
but nobody actually bought them during the selected time period.
*/

USE AdventureWorks2022;  -- choose the database we are working in
GO

-- Create the function (or update it if it already exists)
CREATE OR ALTER FUNCTION dbo.ufn_R4_NeverSoldSKUs
(
    @Rolling7 bit,                    -- 1 means last 7 days, 0 means current week
    @Category nvarchar(50) = NULL,    -- user can filter by category if they want
    @Subcategory nvarchar(50) = NULL, -- user can filter by subcategory
    @AsOf datetime2 = NULL            -- lets user pick a custom date/time
)
RETURNS TABLE
AS
RETURN

-- This part is just figuring out what date range we are checking
WITH Params AS
(
    SELECT
        -- If user doesn't give a date, just use current system time
        AsOfTime = COALESCE(@AsOf, SYSDATETIME()),

        -- Decide where the time window starts
        WinStart =
            CASE
                -- If Rolling7 = 1, go back 7 days
                WHEN @Rolling7 = 1
                    THEN DATEADD(day, -7, COALESCE(@AsOf, SYSDATETIME()))

                -- Otherwise start at beginning of current week
                ELSE
                    CONVERT(datetime2,
                        DATEADD(day,
                                1 - DATEPART(weekday, CONVERT(date, COALESCE(@AsOf, SYSDATETIME()))),
                                CONVERT(date, COALESCE(@AsOf, SYSDATETIME()))
                        )
                    )
            END
),

-- This gets all products that are currently allowed to be sold
Prod AS
(
    SELECT
        p.ProductID,                  -- product ID number
        SKU = p.ProductNumber,        -- product SKU code
        p.Name,                       -- product name
        UnitPrice = p.ListPrice,      -- price of product

        -- This checks if product has stopped being sold
        DiscontinuedFlag =
            CASE
                WHEN p.SellEndDate IS NOT NULL
                     AND p.SellEndDate <= (SELECT AsOfTime FROM Params)
                THEN 1 ELSE 0
            END,

        -- This counts how long product has existed
        DaysListed =
            CASE
                WHEN p.SellStartDate IS NULL THEN NULL
                ELSE DATEDIFF(day, p.SellStartDate,
                              (SELECT AsOfTime FROM Params))
            END,

        pc.Name AS Category,     -- category name
        psc.Name AS Subcategory  -- subcategory name

    FROM Production.Product p

    -- These joins are only to get category info
    LEFT JOIN Production.ProductSubcategory psc
        ON psc.ProductSubcategoryID = p.ProductSubcategoryID

    LEFT JOIN Production.ProductCategory pc
        ON pc.ProductCategoryID = psc.ProductCategoryID

    -- Only include products that are currently sellable
    WHERE
        (p.SellStartDate IS NULL OR
         p.SellStartDate <= (SELECT AsOfTime FROM Params))
    AND (p.SellEndDate IS NULL OR
         p.SellEndDate > (SELECT AsOfTime FROM Params))

    -- Optional filters
    AND (@Category IS NULL OR pc.Name = @Category)
    AND (@Subcategory IS NULL OR psc.Name = @Subcategory)
),

-- This checks which products actually DID get sold
SoldInWindow AS
(
    SELECT DISTINCT d.ProductID  -- only need unique product IDs

    FROM Sales.SalesOrderDetail d

    -- Join to header so we can check order date
    JOIN Sales.SalesOrderHeader h
        ON h.SalesOrderID = d.SalesOrderID

    CROSS JOIN Params prm  -- lets us use the time window values

    WHERE
        h.OnlineOrderFlag = 1   -- only online orders
        AND h.OrderDate >= prm.WinStart
        AND h.OrderDate < prm.AsOfTime
)

-- Final output
SELECT
    p.ProductID,
    p.SKU,
    p.Name,
    p.UnitPrice,
    p.DiscontinuedFlag,
    p.DaysListed,

    -- Just marking that it had zero sales
    ZeroSalesFlag = CAST(1 AS bit)

FROM Prod p

-- Try to match product to sold products
LEFT JOIN SoldInWindow s
    ON s.ProductID = p.ProductID

-- If there is no match, that means it was never sold
WHERE s.ProductID IS NULL;
GO

SELECT * 
FROM dbo.ufn_R4_NeverSoldSKUs(0,NULL,NULL,NULL);

SELECT *
FROM dbo.ufn_R4_NeverSoldSKUs(1,'Bikes',NULL,NULL);

