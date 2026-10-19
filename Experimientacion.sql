
USE Panaderia;
GO
-- Tabla de registro de errores (C5: TRY/CATCH registra el error)
IF OBJECT_ID('dbo.LogErrores') IS NULL
    CREATE TABLE dbo.LogErrores(
        IdLog INT IDENTITY(1,1) PRIMARY KEY,
        Fecha DATETIME NOT NULL DEFAULT GETDATE(),
        Objeto SYSNAME NULL, Numero INT NULL, Mensaje NVARCHAR(4000) NULL);
GO
/* ---------- C4.1 FUNCIÓN: estado del stock (usa CASE) ---------- */
CREATE OR ALTER FUNCTION dbo.fn_EstadoStock(@IdProducto INT)
RETURNS VARCHAR(10)
AS
BEGIN
    DECLARE @s INT, @m INT;
    SELECT @s = Stock, @m = StockMinimo FROM dbo.Productos WHERE IdProducto = @IdProducto;
    RETURN CASE WHEN @s IS NULL THEN NULL
                WHEN @s <= 0      THEN 'AGOTADO'
                WHEN @s <= @m     THEN 'CRITICO'
                WHEN @s <= @m * 2 THEN 'BAJO'
                ELSE 'OK' END;
END;
GO
/* ---------- C4.2 VISTA: productos a reponer ---------- */
CREATE OR ALTER VIEW dbo.vw_ProductosReponer
AS
SELECT p.IdProducto, p.Nombre, c.Nombre AS Categoria, p.Stock, p.StockMinimo,
       dbo.fn_EstadoStock(p.IdProducto) AS Estado
FROM dbo.Productos p
JOIN dbo.Categorias c ON c.IdCategoria = p.IdCategoria
WHERE p.Stock <= p.StockMinimo * 2;
GO
/* ---------- C4.3 TRIGGER: descuenta stock al registrar una línea de venta ----------
   Finalidad: el inventario es el problema central del proyecto; evita depender de que
   cada aplicación recuerde actualizar el stock. Solo actúa sobre inserciones nuevas. */
CREATE OR ALTER TRIGGER dbo.trg_DetalleVenta_DescuentaStock
ON dbo.DetalleVenta
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE p
       SET p.Stock = p.Stock - i.Cant
    FROM dbo.Productos p
    JOIN (SELECT IdProducto, SUM(Cantidad) AS Cant FROM inserted GROUP BY IdProducto) i
      ON i.IdProducto = p.IdProducto;
END;
GO
/* ---------- C4.4 / C5 PROCEDIMIENTO parametrizado con transacción ----------
   Varios cambios: (1) cabecera en Ventas, (2) línea en DetalleVenta (el trigger descuenta
   stock), (3) actualiza Total. Si el stock no alcanza, se revierte TODO. */
CREATE OR ALTER PROCEDURE dbo.sp_RegistrarVenta
    @IdCliente INT, @IdEmpleado INT, @MetodoPago VARCHAR(50),
    @IdProducto INT, @Cantidad INT, @IdVenta INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        IF @Cantidad IS NULL OR @Cantidad <= 0
            THROW 50001, 'La cantidad debe ser mayor que cero.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Productos WHERE IdProducto = @IdProducto)
            THROW 50002, 'El producto no existe.', 1;

        BEGIN TRAN;
            INSERT INTO dbo.Ventas(IdCliente, IdEmpleado, FechaVenta, MetodoPago, Total)
            VALUES (@IdCliente, @IdEmpleado, GETDATE(), @MetodoPago, 0);
            SET @IdVenta = SCOPE_IDENTITY();

            -- La validación ocurre DESPUÉS de insertar la cabecera, para demostrar que el
            -- ROLLBACK elimina también los cambios ya hechos.
            IF (SELECT Stock FROM dbo.Productos WHERE IdProducto = @IdProducto) < @Cantidad
                THROW 50003, 'Stock insuficiente para completar la venta.', 1;

            INSERT INTO dbo.DetalleVenta(IdVenta, IdProducto, Cantidad, PrecioUnitario)
            SELECT @IdVenta, @IdProducto, @Cantidad, PrecioVenta
            FROM dbo.Productos WHERE IdProducto = @IdProducto;

            UPDATE dbo.Ventas
               SET Total = (SELECT SUM(Cantidad * PrecioUnitario) FROM dbo.DetalleVenta WHERE IdVenta = @IdVenta)
             WHERE IdVenta = @IdVenta;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        INSERT INTO dbo.LogErrores(Objeto, Numero, Mensaje)
        VALUES (OBJECT_NAME(@@PROCID), ERROR_NUMBER(), ERROR_MESSAGE());
        SET @IdVenta = NULL;
        THROW;                                   -- propaga el error al llamador
    END CATCH;
END;
GO

---------------- PRUEBAS  ----

-- PRUEBA 1 : función y vista
SELECT TOP 1 IdProducto, Nombre, Stock, StockMinimo, dbo.fn_EstadoStock(IdProducto) AS Estado
FROM dbo.Productos ORDER BY IdProducto;
SELECT TOP 10 * FROM dbo.vw_ProductosReponer ORDER BY Stock;
GO

-- PRUEBA 2: caso VÁLIDO -> COMMIT y el trigger descuenta stock
DECLARE @p INT, @c INT, @e INT, @v INT;
SELECT TOP 1 @p = IdProducto FROM dbo.Productos ORDER BY IdProducto;
SELECT TOP 1 @c = IdCliente FROM dbo.Clientes ORDER BY IdCliente;
SELECT TOP 1 @e = IdEmpleado FROM dbo.Empleados ORDER BY IdEmpleado;
SELECT 'ANTES' AS momento, Stock, (SELECT COUNT(*) FROM dbo.Ventas) AS ventas
FROM dbo.Productos WHERE IdProducto = @p;
EXEC dbo.sp_RegistrarVenta @c, @e, 'Efectivo', @p, 2, @v OUTPUT;
SELECT 'DESPUES' AS momento, Stock, (SELECT COUNT(*) FROM dbo.Ventas) AS ventas, @v AS venta_creada
FROM dbo.Productos WHERE IdProducto = @p;
SELECT * FROM dbo.Ventas WHERE IdVenta = @v;
SELECT * FROM dbo.DetalleVenta WHERE IdVenta = @v;
GO
-- PRUEBA 3: caso con ERROR provocado (stock insuficiente) -> ROLLBACK sin cambios parciales
DECLARE @p INT, @c INT, @e INT, @v INT;
SELECT TOP 1 @p = IdProducto FROM dbo.Productos ORDER BY IdProducto;
SELECT TOP 1 @c = IdCliente FROM dbo.Clientes ORDER BY IdCliente;
SELECT TOP 1 @e = IdEmpleado FROM dbo.Empleados ORDER BY IdEmpleado;
SELECT 'ANTES' AS momento, Stock, (SELECT COUNT(*) FROM dbo.Ventas) AS ventas, 
(SELECT MAX(IdVenta) FROM dbo.Ventas) AS ultima_venta FROM dbo.Productos WHERE IdProducto = @p;
BEGIN TRY
    EXEC dbo.sp_RegistrarVenta @c, @e, 'Efectivo', @p, 999999, @v OUTPUT;
END TRY
BEGIN CATCH
    SELECT 'ERROR CAPTURADO' AS resultado, ERROR_NUMBER() AS numero, ERROR_MESSAGE() AS mensaje;
END CATCH;
SELECT 'DESPUES' AS momento, Stock, (SELECT COUNT(*) FROM dbo.Ventas) AS ventas,
(SELECT MAX(IdVenta) FROM dbo.Ventas) AS ultima_venta FROM dbo.Productos WHERE IdProducto = @p;
SELECT TOP 3 * FROM dbo.LogErrores ORDER BY IdLog DESC;      -- el error quedó registrado
GO
-- PRUEBA 4 (C4): IF/CASE + CURSOR acotado (sugerencia de reposición)
DECLARE @id INT, @n VARCHAR(100), @s INT, @m INT, @sug INT;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT TOP 5 IdProducto, Nombre, Stock, StockMinimo FROM dbo.vw_ProductosReponer ORDER BY Stock;
OPEN cur;
FETCH NEXT FROM cur INTO @id, @n, @s, @m;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sug = @m * 3 - @s;
    IF @sug > 0 PRINT CONCAT('Reponer ', @sug, ' unidades de ', @n, ' (', dbo.fn_EstadoStock(@id), ')');
    ELSE        PRINT CONCAT(@n, ': sin reposición necesaria');
    FETCH NEXT FROM cur INTO @id, @n, @s, @m;
END;
CLOSE cur; DEALLOCATE cur;
GO
      
