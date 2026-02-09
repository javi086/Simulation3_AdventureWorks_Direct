/*====================================================================
  COURSE: SQL Server Development
  NAME:Jose Javier Santana Vera
  STUDENT ID: N01753766
  SIMULATION 3: Keys, Constraints & Joins in the AdventureWorks DB
  DATABASE: AdventureWorks2022

====================================================================*/

USE AdventureWorks2025;
GO

/*
Based on the simulations 3 instrucctions, we need to ensure that our scripts can run multiple times without causing errors. 
This is part of the requested in 01_create_schema_and_tables.sql by the term Idempotent
*/

/*====================================================================
  PRE-FLIGHT CHECKS
====================================================================*/
IF DB_ID(N'AdventureWorks2025') IS NULL -- This is the initial validation agains the DB existence
BEGIN -- This help us to group multiple statements into the IF clause
    RAISERROR('AdventureWorks2025 database not found. Install/restore AdventureWorks2022 before running.', 16, 1); -- If the DB does not exists, this will throw an error, 16 means user level error
    SET NOEXEC ON; -- In case of any error this ensure that the execution does not continue with the rest of the commands
    RETURN;
END
GO 


/*====================================================================
  0) CHECK SCHEMA EXISTENCY
====================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'Sim') -- This is validating that inside sys.schemas the 'Sim' schema already exists.  
   EXEC('CREATE SCHEMA Sim AUTHORIZATION dbo;'); -- In case the 'Sim' schema does not exist, it will be created. "AUTHORIZATION dbo", gives full permissions.
GO


/*==========================================================
  1) DROP EXISTING SIM OBJECTS
=========================================================*/
-- Here we are validating if the reports exist and if it's so, they will be elminated using DROP PROCEDURE - Procedures (P)
IF OBJECT_ID(N'Sim.usp_Ready_to_Ship_Orders', N'P') IS NOT NULL DROP PROCEDURE Sim.usp_Ready_to_Ship_Orders;
-- We need to add the other reports here based on our progress
GO

/* The following lines look for the main four tables (U - User Tables) inside the 'Sim' schema prevously created and if the four tables exist, they will be eliminated */
/* Additionally, the deletion of the tables starts for the children tables, those that have a foreign key pointing to the parent tables. 
Parent tables cannot eleminated befeore children tablese*/
IF OBJECT_ID(N'Sim.SalesOrderLine', 'U') IS NOT NULL DROP TABLE Sim.SalesOrderLine;
IF OBJECT_ID(N'Sim.SalesOrder',     'U') IS NOT NULL DROP TABLE Sim.SalesOrder;
IF OBJECT_ID(N'Sim.Customer',        'U') IS NOT NULL DROP TABLE Sim.Customer;
IF OBJECT_ID(N'Sim.Product',         'U') IS NOT NULL DROP TABLE Sim.Product;
GO


/*====================================================================
  3) FOUR MAIN TABLES
====================================================================*/
--Custoemr

SELECT * INTO Sim.Customer FROM Sales.Customer WHERE 1 = 0;
GO

ALTER TABLE Sim.Customer
  ADD CONSTRAINT PK_Sim_Customer PRIMARY KEY CLUSTERED (CustomerID);

ALTER TABLE Sim.Customer
  ADD CONSTRAINT FK_SimCustomer_To_SalesCustomer
      FOREIGN KEY (CustomerID) REFERENCES Sales.Customer(CustomerID);
GO



-- Product
SELECT * INTO Sim.Product FROM Production.Product WHERE 1 = 0;
GO

ALTER TABLE Sim.Product
  ADD CONSTRAINT PK_Sim_Product PRIMARY KEY CLUSTERED (ProductID);

ALTER TABLE Sim.Product
  ADD CONSTRAINT FK_SimProduct_To_ProdProduct
      FOREIGN KEY (ProductID) REFERENCES Production.Product(ProductID);
GO

-- SalesOrder

CREATE TABLE Sim.SalesOrder
(
    SalesOrderID  INT           NOT NULL,  -- PK (copy from source)
    CustomerID    INT           NOT NULL,  -- FK -> Sim.Customer
    OrderDate     DATETIME2     NOT NULL,
    Channel       NVARCHAR(8)   NOT NULL CONSTRAINT DF_SimSO_Channel DEFAULT(N'AWD'),
    [Status]      TINYINT       NULL,
    StatusDesc    NVARCHAR(20)  NULL,
    TerritoryID   INT           NULL,
    SubTotal      DECIMAL(19,4) NULL,
    TaxAmt        DECIMAL(19,4) NULL,
    Freight       DECIMAL(19,4) NULL,
    PromoRate     DECIMAL(4,3)  NOT NULL CONSTRAINT DF_SimSO_PromoRate DEFAULT(0.000),
    TotalDue      DECIMAL(19,4) NOT NULL,
    CreatedAt     DATETIME2     NOT NULL CONSTRAINT DF_SimSO_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt     DATETIME2     NOT NULL CONSTRAINT DF_SimSO_UpdatedAt DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT PK_Sim_SalesOrder PRIMARY KEY CLUSTERED (SalesOrderID),
    CONSTRAINT FK_SimSO_Customer FOREIGN KEY (CustomerID) REFERENCES Sim.Customer(CustomerID),
    CONSTRAINT CK_SimSO_PromoRate CHECK (PromoRate BETWEEN 0.000 AND 0.500)
);
GO

-- SalesOrderOnline

CREATE TABLE Sim.SalesOrderLine
(
    SalesOrderID  INT           NOT NULL,  -- FK -> Sim.SalesOrder
    LineNumber    INT           NOT NULL,  -- 1..N per order
    ProductID     INT           NOT NULL,  -- FK -> Sim.Product
    Quantity      INT           NOT NULL,
    UnitPrice     DECIMAL(19,4) NOT NULL,
    DiscountRate  DECIMAL(4,3)  NOT NULL CONSTRAINT DF_SimSOL_Discount DEFAULT(0.000),
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
    