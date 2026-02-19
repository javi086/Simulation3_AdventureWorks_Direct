/*====================================================================
  SCRIPT: 06_defect_injection_and_fix.sql
  PURPOSE: Demonstrate controlled defect drill and FK lifecycle
           (Event C — Ingest Defect)
  NAME: THOMPSON BONSU OSEI
  STUDENT ID: N01714324
  DATABASE: AdventureWorks2025
====================================================================*/

USE AdventureWorks2025;
GO

/*====================================================================
  STEP 1: Disable FK Constraint
  Event C trigger: simulate defect ingestion by allowing orphan rows
====================================================================*/
PRINT 'Step 1: Disable FK_SimSOL_SalesOrder (not trusted)';
ALTER TABLE Sim.SalesOrderLine NOCHECK CONSTRAINT FK_SimSOL_SalesOrder;
GO

-- Verify status
SELECT name, is_disabled, is_not_trusted
FROM sys.foreign_keys
WHERE name = 'FK_SimSOL_SalesOrder';
GO


/*====================================================================
  STEP 2: Insert Bad Data (Orphan Line)
  Event C trigger: defective batch ingestion
====================================================================*/
PRINT 'Step 2: Insert orphan row (bad SalesOrderID = 999999)';
INSERT INTO Sim.SalesOrderLine
(SalesOrderID, LineNumber, ProductID, Quantity, UnitPrice, DiscountRate)
VALUES 
(999999, 1, 1, 5, 100.00, 0.10);
GO

-- Confirm insertion
SELECT * FROM Sim.SalesOrderLine WHERE SalesOrderID = 0.10;
GO


/*====================================================================
  STEP 3: Attempt to Re-enable FK
  Expect failure due to orphan row
====================================================================*/
PRINT 'Step 3: Attempt re-enable FK (expected failure)';
BEGIN TRY
    ALTER TABLE Sim.SalesOrderLine WITH CHECK CHECK CONSTRAINT FK_SimSOL_SalesOrder;
    PRINT 'FK re-enable succeeded unexpectedly';
END TRY
BEGIN CATCH
    PRINT 'Expected failure: cannot enable FK due to orphan row';
    PRINT ERROR_MESSAGE();
END CATCH
GO


/*====================================================================
  STEP 4: Fix Bad Data
  Delete orphan row or correct SalesOrderID
====================================================================*/
PRINT 'Step 4: Fix defect by deleting orphan row';
DELETE FROM Sim.SalesOrderLine
WHERE SalesOrderID = 999999;
GO

-- Verify deletion
SELECT * FROM Sim.SalesOrderLine WHERE SalesOrderID = 999999;
GO


/*====================================================================
  STEP 5: Re-enable FK Successfully
====================================================================*/
PRINT 'Step 5: Re-enable FK after fix';
ALTER TABLE Sim.SalesOrderLine WITH CHECK CHECK CONSTRAINT FK_SimSOL_SalesOrder;
GO

-- Verify FK status is trusted
SELECT name, is_disabled, is_not_trusted
FROM sys.foreign_keys
WHERE name = 'FK_SimSOL_SalesOrder';
GO

PRINT 'Defect drill completed successfully';

SELECT 
    name AS FK_Name,
    parent_object_id AS Table_Object_ID,
    is_disabled,
    is_not_trusted,
    is_not_for_replication
FROM sys.foreign_keys
WHERE name = 'FK_SimSOL_SalesOrder';
GO