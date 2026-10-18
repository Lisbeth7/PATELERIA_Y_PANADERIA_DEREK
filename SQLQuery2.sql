

-- CONTROL, CALIDAD Y STAGING 

IF OBJECT_ID('etl.config','U') IS NULL
CREATE TABLE etl.config(clave VARCHAR(50) NOT NULL PRIMARY KEY, valor VARCHAR(100) NOT NULL);
IF NOT EXISTS (SELECT 1 FROM etl.config WHERE clave='sal_cliente')
    INSERT etl.config VALUES ('sal_cliente','DEREK-2026-CAMBIAR');      -- CAMBIA ESTA SAL ANTES DE CARGAR
IF NOT EXISTS (SELECT 1 FROM etl.config WHERE clave='politica_rechazo')
    INSERT etl.config VALUES ('politica_rechazo','QUARANTINE');         -- QUARANTINE = carga lo valido | STRICT = falla si hay rechazos
IF NOT EXISTS (SELECT 1 FROM etl.config WHERE clave='cliente_nulo_cuarentena')
    INSERT etl.config VALUES ('cliente_nulo_cuarentena','0'); -- 1 = venta sin cliente va a cuarentena
IF NOT EXISTS (SELECT 1 FROM etl.config WHERE clave='umbral_rechazo_pct')
    INSERT etl.config VALUES ('umbral_rechazo_pct','1');          
GO

IF OBJECT_ID('etl.ejecucion','U') IS NULL
CREATE TABLE etl.ejecucion(
    id_carga            INT IDENTITY(1,1) PRIMARY KEY,
    tipo                VARCHAR(5)    NOT NULL,   -- ETL o ELT
    inicio              DATETIME2(0)  NOT NULL,
    fin                 DATETIME2(0)  NULL,
    filas_leidas        INT NOT NULL DEFAULT 0,
    filas_cargadas      INT NOT NULL DEFAULT 0,
    filas_actualizadas  INT NOT NULL DEFAULT 0,
    filas_existentes    INT NOT NULL DEFAULT 0,
    filas_rechazadas    INT NOT NULL DEFAULT 0,
    estado              VARCHAR(20)   NOT NULL,  -- EN CURSO / OK / ADVERTENCIA / ERROR
    mensaje             NVARCHAR(500) NULL
);
IF OBJECT_ID('etl.rechazados','U') IS NULL
CREATE TABLE etl.rechazados(
    id_rechazo     BIGINT IDENTITY(1,1) PRIMARY KEY,
    id_carga       INT           NOT NULL,
    tabla_origen   VARCHAR(30)   NOT NULL,  -- fact_ventas / fact_compras
    clave_natural  VARCHAR(40)   NULL,
    monto          DECIMAL(19,4) NULL,
    motivo         NVARCHAR(500) NOT NULL,
    fecha_registro DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
IF OBJECT_ID('etl.perfilado','U') IS NULL
CREATE TABLE etl.perfilado(
    id_perfil BIGINT IDENTITY(1,1) PRIMARY KEY,
    id_carga  INT          NOT NULL,
    tabla     VARCHAR(40)  NOT NULL,
    metrica   VARCHAR(60)  NOT NULL,
    valor     DECIMAL(18,2) NULL
);
GO

-- Staging 
DROP TABLE IF EXISTS staging.ventas_linea;
DROP TABLE IF EXISTS staging.compras_linea;
DROP TABLE IF EXISTS staging.productos;
DROP TABLE IF EXISTS staging.clientes;
DROP TABLE IF EXISTS staging.empleados;
DROP TABLE IF EXISTS staging.proveedores;
DROP TABLE IF EXISTS staging.estados_pedido;
GO
CREATE TABLE staging.productos(
    IdProducto int NOT NULL, Nombre nvarchar(150) NOT NULL, Categoria nvarchar(100) NOT NULL,
    PrecioCompra decimal(10,2) NOT NULL, PrecioVenta decimal(10,2) NOT NULL,
    Stock int NOT NULL, StockMinimo int NOT NULL);
CREATE TABLE staging.clientes(IdCliente int NOT NULL, FechaRegistro date NULL);
CREATE TABLE staging.empleados(IdEmpleado int NOT NULL, Nombre nvarchar(150) NOT NULL, Cargo nvarchar(100) NOT NULL);
CREATE TABLE staging.proveedores(IdProveedor int NOT NULL, Ruc varchar(20) NULL, Nombre nvarchar(150) NOT NULL);
CREATE TABLE staging.estados_pedido(IdEstado int NOT NULL, Nombre nvarchar(60) NOT NULL);
-- Hechos: las claves y medidas admiten NULL para poder detectarlas y rechazarlas
CREATE TABLE staging.ventas_linea(
    id_carga int NOT NULL, IdDetalleVenta int NULL, IdVenta int NULL, IdProducto int NULL,
    Cantidad int NULL, PrecioUnitario decimal(12,2) NULL, Subtotal decimal(12,2) NULL,
    FechaVenta datetime NULL, IdCliente int NULL, IdEmpleado int NULL, MetodoPago varchar(50) NOT NULL);
CREATE TABLE staging.compras_linea(
    id_carga int NOT NULL, IdDetallePedido int NULL, IdPedido int NULL, IdProducto int NULL,
    Cantidad int NULL, PrecioUnitario decimal(12,2) NULL, Subtotal decimal(12,2) NULL,
    FechaPedido datetime NULL, FechaEntrega datetime NULL, IdProveedor int NULL, IdEstado int NULL);
GO

-- Zona RAW del ELT: todo en texto, tal como llega
IF OBJECT_ID('elt.raw_ventas_linea','U') IS NULL
CREATE TABLE elt.raw_ventas_linea(
    id_carga int NULL, archivo varchar(200) NULL,
    IdDetalleVenta nvarchar(50) NULL, IdVenta nvarchar(50) NULL, IdProducto nvarchar(50) NULL,
    Cantidad nvarchar(50) NULL, PrecioUnitario nvarchar(50) NULL, Subtotal nvarchar(50) NULL,
    FechaVenta nvarchar(50) NULL, IdCliente nvarchar(50) NULL, IdEmpleado nvarchar(50) NULL,
    MetodoPago nvarchar(50) NULL);
IF OBJECT_ID('elt.raw_compras_linea','U') IS NULL
CREATE TABLE elt.raw_compras_linea(
    id_carga int NULL, archivo varchar(200) NULL,
    IdDetallePedido nvarchar(50) NULL, IdPedido nvarchar(50) NULL, IdProducto nvarchar(50) NULL,
    Cantidad nvarchar(50) NULL, PrecioUnitario nvarchar(50) NULL, Subtotal nvarchar(50) NULL,
    FechaPedido nvarchar(50) NULL, FechaEntrega nvarchar(50) NULL,
    IdProveedor nvarchar(50) NULL, IdEstado nvarchar(50) NULL);
GO
CREATE OR ALTER VIEW elt.v_csv_ventas_linea AS     -- destino de BULK INSERT desde CSV
SELECT IdDetalleVenta, IdVenta, IdProducto, Cantidad, PrecioUnitario, Subtotal,
       FechaVenta, IdCliente, IdEmpleado, MetodoPago
FROM elt.raw_ventas_linea;
GO

-- EXTRACCION A STAGING --

--  Dimensiones (compartida por ETL y ELT)
CREATE OR ALTER PROCEDURE etl.sp_extraer_dimensiones @id_carga INT
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE staging.productos;  TRUNCATE TABLE staging.clientes;
    TRUNCATE TABLE staging.empleados;  TRUNCATE TABLE staging.proveedores;
    TRUNCATE TABLE staging.estados_pedido;

    INSERT staging.productos(IdProducto, Nombre, Categoria, PrecioCompra, PrecioVenta, Stock, StockMinimo)
    SELECT p.IdProducto,
           COALESCE(NULLIF(LTRIM(RTRIM(p.Nombre)),N''), N'Sin nombre'),
           COALESCE(NULLIF(LTRIM(RTRIM(c.Nombre)),N''), N'Sin categoria'),
           COALESCE(p.PrecioCompra,0), COALESCE(p.PrecioVenta,0),
           COALESCE(p.Stock,0), COALESCE(p.StockMinimo,0)
    FROM Panaderia.dbo.Productos p
    LEFT JOIN Panaderia.dbo.Categorias c ON c.IdCategoria = p.IdCategoria;

    INSERT staging.clientes(IdCliente, FechaRegistro)          -- nombre y telefono NO salen del OLTP
    SELECT c.IdCliente, CAST(c.FechaRegistro AS date) FROM Panaderia.dbo.Clientes c;

    INSERT staging.empleados(IdEmpleado, Nombre, Cargo)
    SELECT e.IdEmpleado, COALESCE(LTRIM(RTRIM(e.Nombre)),N'Sin nombre'), COALESCE(LTRIM(RTRIM(e.Cargo)),N'Sin cargo')
    FROM Panaderia.dbo.Empleados e;

    INSERT staging.proveedores(IdProveedor, Ruc, Nombre)
    SELECT s.IdProveedor, LTRIM(RTRIM(s.Ruc)), COALESCE(LTRIM(RTRIM(s.Nombre)),N'Sin nombre')
    FROM Panaderia.dbo.Proveedores s;

    INSERT staging.estados_pedido(IdEstado, Nombre)
    SELECT e.IdEstado, COALESCE(LTRIM(RTRIM(e.Nombre)),N'Sin nombre')
    FROM Panaderia.dbo.EstadosPedido e;
END;
GO

-- Hechos para ETL 


CREATE OR ALTER PROCEDURE etl.sp_extraer_hechos
    @id_carga INT
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE staging.ventas_linea;
    TRUNCATE TABLE staging.compras_linea;

    -- Extraer líneas de ventas
    INSERT INTO staging.ventas_linea
    (
        id_carga,
        IdDetalleVenta,
        IdVenta,
        IdProducto,
        Cantidad,
        PrecioUnitario,
        Subtotal,
        FechaVenta,
        IdCliente,
        IdEmpleado,
        MetodoPago
    )
    SELECT
        @id_carga,
        d.IdDetalle,
        d.IdVenta,
        d.IdProducto,
        d.Cantidad,
        d.PrecioUnitario,
        d.Subtotal,
        v.FechaVenta,
        v.IdCliente,
        v.IdEmpleado,
        COALESCE(
            NULLIF(LTRIM(RTRIM(v.MetodoPago)), ''),
            'NO ESPECIFICADO'
        )
    FROM Panaderia.dbo.DetalleVenta AS d
    LEFT JOIN Panaderia.dbo.Ventas AS v
        ON v.IdVenta = d.IdVenta;

    -- Extraer líneas de compras
    INSERT INTO staging.compras_linea
    (
        id_carga,
        IdDetallePedido,
        IdPedido,
        IdProducto,
        Cantidad,
        PrecioUnitario,
        Subtotal,
        FechaPedido,
        FechaEntrega,
        IdProveedor,
        IdEstado
    )
    SELECT
        @id_carga,
        d.IdDetallePedido,
        d.IdPedido,
        d.IdProducto,
        d.Cantidad,
        d.PrecioCompra,
        d.Subtotal,
        h.FechaPedido,
        h.FechaEntrega,
        h.IdProveedor,
        h.IdEstado
    FROM Panaderia.dbo.DetallePedido AS d
    LEFT JOIN Panaderia.dbo.PedidosProveedor AS h
        ON h.IdPedido = d.IdPedido;
END;
GO


-- Perfilado previo a la limpieza
CREATE OR ALTER PROCEDURE etl.sp_perfilar @id_carga INT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT etl.perfilado(id_carga, tabla, metrica, valor)
    SELECT @id_carga,'ventas_linea','filas', COUNT(*) FROM staging.ventas_linea UNION ALL
    SELECT @id_carga,'ventas_linea','campos_obligatorios_nulos',
           SUM(CASE WHEN IdProducto IS NULL OR FechaVenta IS NULL OR Cantidad IS NULL OR PrecioUnitario IS NULL
                    THEN 1 ELSE 0 END) FROM staging.ventas_linea UNION ALL
    SELECT @id_carga,'ventas_linea','duplicados', COUNT(*) - COUNT(DISTINCT IdDetalleVenta) FROM staging.ventas_linea UNION ALL
    SELECT @id_carga,'ventas_linea','cantidad_no_positiva', SUM(CASE WHEN Cantidad <= 0 THEN 1 ELSE 0 END) FROM staging.ventas_linea UNION ALL
    SELECT @id_carga,'ventas_linea','subtotal_inconsistente',
           SUM(CASE WHEN ABS(ISNULL(Subtotal,0) - ISNULL(Cantidad,0) * ISNULL(PrecioUnitario,0)) > 0.005 THEN 1 ELSE 0 END)
           FROM staging.ventas_linea UNION ALL
    SELECT @id_carga,'ventas_linea','fecha_min_AAAAMMDD', MIN(CONVERT(int, CONVERT(char(8), FechaVenta, 112))) FROM staging.ventas_linea UNION ALL
    SELECT @id_carga,'ventas_linea','fecha_max_AAAAMMDD', MAX(CONVERT(int, CONVERT(char(8), FechaVenta, 112))) FROM staging.ventas_linea UNION ALL
    SELECT @id_carga,'compras_linea','filas', COUNT(*) FROM staging.compras_linea UNION ALL
    SELECT @id_carga,'compras_linea','campos_obligatorios_nulos',
           SUM(CASE WHEN IdProducto IS NULL OR FechaPedido IS NULL OR Cantidad IS NULL OR PrecioUnitario IS NULL
                         OR IdProveedor IS NULL THEN 1 ELSE 0 END) FROM staging.compras_linea UNION ALL
    SELECT @id_carga,'compras_linea','duplicados', COUNT(*) - COUNT(DISTINCT IdDetallePedido) FROM staging.compras_linea UNION ALL
    SELECT @id_carga,'compras_linea','cantidad_no_positiva', SUM(CASE WHEN Cantidad <= 0 THEN 1 ELSE 0 END) FROM staging.compras_linea;
END;
GO

--CARGA DE DIMENSIONES 
CREATE OR ALTER PROCEDURE etl.sp_cargar_dimensiones @id_carga INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @hoy date = CAST(GETDATE() AS date);

        /* ---- dim_fecha (estatica): miembro 0 + calendario del lote + hoy ---- */
        IF NOT EXISTS (SELECT 1 FROM dw.dim_fecha WHERE sk_fecha = 0)
            INSERT dw.dim_fecha(sk_fecha, fecha, anio, trimestre, mes, nombre_mes, dia, dia_semana, nombre_dia, es_fin_semana)
            VALUES (0, '19000101', 1900, 1, 1, 'Sin fecha', 1, 1, 'Sin fecha', 0);

        DECLARE @min date = @hoy, @max date = @hoy;
        SELECT @min = MIN(f), @max = MAX(f)
        FROM (SELECT CAST(FechaVenta AS date) f FROM staging.ventas_linea
              UNION ALL SELECT CAST(FechaPedido AS date)  FROM staging.compras_linea
              UNION ALL SELECT CAST(FechaEntrega AS date) FROM staging.compras_linea
              UNION ALL SELECT @hoy) x
        WHERE f IS NOT NULL AND f >= '20000101';
        IF @min IS NULL SET @min = @hoy;
        IF @max IS NULL SET @max = @hoy;

        ;WITH d AS (
            SELECT @min AS f
            UNION ALL
            SELECT DATEADD(day, 1, f) FROM d WHERE f < @max
        )
        INSERT dw.dim_fecha(sk_fecha, fecha, anio, trimestre, mes, nombre_mes, dia, dia_semana, nombre_dia, es_fin_semana)
        SELECT CONVERT(int, CONVERT(char(8), f, 112)), f, YEAR(f), DATEPART(quarter, f), MONTH(f),
               CHOOSE(MONTH(f),'Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio','Agosto',
                               'Setiembre','Octubre','Noviembre','Diciembre'),
               DAY(f), (DATEDIFF(day,'19000101',f) % 7) + 1,
               CHOOSE((DATEDIFF(day,'19000101',f) % 7) + 1,'Lunes','Martes','Miercoles','Jueves','Viernes','Sabado','Domingo'),
               CASE WHEN (DATEDIFF(day,'19000101',f) % 7) + 1 >= 6 THEN 1 ELSE 0 END
        FROM d
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_fecha x WHERE x.fecha = d.f)
        OPTION (MAXRECURSION 0);

        /* ---- dim_metodo_pago (estatica: solo inserta valores nuevos) ---- */
        INSERT dw.dim_metodo_pago(metodo_pago, tipo_pago)
        SELECT m.MetodoPago,
               CASE WHEN UPPER(m.MetodoPago) LIKE '%EFECTIVO%' THEN 'Efectivo'
                    WHEN UPPER(m.MetodoPago) LIKE '%YAPE%' OR UPPER(m.MetodoPago) LIKE '%PLIN%'
                      OR UPPER(m.MetodoPago) LIKE '%BILLETERA%' OR UPPER(m.MetodoPago) LIKE '%DIGITAL%' THEN 'Billetera digital'
                    WHEN UPPER(m.MetodoPago) LIKE '%TARJETA%' OR UPPER(m.MetodoPago) LIKE '%VISA%'
                      OR UPPER(m.MetodoPago) LIKE '%MASTER%' OR UPPER(m.MetodoPago) LIKE '%CREDITO%'
                      OR UPPER(m.MetodoPago) LIKE '%DEBITO%' THEN 'Tarjeta'
                    ELSE 'Otro' END
        FROM (SELECT DISTINCT MetodoPago FROM staging.ventas_linea
              UNION SELECT 'NO ESPECIFICADO') m
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_metodo_pago d WHERE d.metodo_pago = m.MetodoPago);

        /* ---- dim_estado_pedido (estatica) + miembro 0 ---- */
        IF NOT EXISTS (SELECT 1 FROM dw.dim_estado_pedido WHERE id_estado = 0)
            INSERT dw.dim_estado_pedido(id_estado, estado) VALUES (0, 'Sin estado');
        INSERT dw.dim_estado_pedido(id_estado, estado)
        SELECT s.IdEstado, s.Nombre FROM staging.estados_pedido s
        WHERE s.IdEstado <> 0 AND NOT EXISTS (SELECT 1 FROM dw.dim_estado_pedido d WHERE d.id_estado = s.IdEstado);

        /* ---- dim_proveedor (SCD 1) + miembro 0 ---- */
        IF NOT EXISTS (SELECT 1 FROM dw.dim_proveedor WHERE id_proveedor = 0)
            INSERT dw.dim_proveedor(id_proveedor, ruc, nombre) VALUES (0, NULL, 'Sin proveedor');
        UPDATE d SET d.ruc = s.Ruc, d.nombre = s.Nombre
        FROM dw.dim_proveedor d JOIN staging.proveedores s ON s.IdProveedor = d.id_proveedor
        WHERE ISNULL(d.ruc,'') <> ISNULL(s.Ruc,'') OR d.nombre <> s.Nombre;
        INSERT dw.dim_proveedor(id_proveedor, ruc, nombre)
        SELECT s.IdProveedor, s.Ruc, s.Nombre FROM staging.proveedores s
        WHERE s.IdProveedor <> 0 AND NOT EXISTS (SELECT 1 FROM dw.dim_proveedor d WHERE d.id_proveedor = s.IdProveedor);

        /* ---- dim_empleado (SCD 1) + miembro 0 ---- */
        IF NOT EXISTS (SELECT 1 FROM dw.dim_empleado WHERE id_empleado = 0)
            INSERT dw.dim_empleado(id_empleado, nombre, cargo) VALUES (0, 'Sin empleado', 'No aplica');
        UPDATE d SET d.nombre = s.Nombre, d.cargo = s.Cargo
        FROM dw.dim_empleado d JOIN staging.empleados s ON s.IdEmpleado = d.id_empleado
        WHERE d.nombre <> s.Nombre OR d.cargo <> s.Cargo;
        INSERT dw.dim_empleado(id_empleado, nombre, cargo)
        SELECT s.IdEmpleado, s.Nombre, s.Cargo FROM staging.empleados s
        WHERE s.IdEmpleado <> 0 AND NOT EXISTS (SELECT 1 FROM dw.dim_empleado d WHERE d.id_empleado = s.IdEmpleado);

        /* ---- dim_cliente (SCD 1; codigo seudonimo, sin datos personales) ---- */
        DECLARE @sal varchar(100) = (SELECT valor FROM etl.config WHERE clave = 'sal_cliente');
        IF NOT EXISTS (SELECT 1 FROM dw.dim_cliente WHERE id_cliente = 0)
            INSERT dw.dim_cliente(id_cliente, codigo_cliente, fecha_registro) VALUES (0, 'SIN-CLIENTE', NULL);
        UPDATE d SET d.fecha_registro = s.FechaRegistro
        FROM dw.dim_cliente d JOIN staging.clientes s ON s.IdCliente = d.id_cliente
        WHERE ISNULL(d.fecha_registro,'19000101') <> ISNULL(s.FechaRegistro,'19000101');
        INSERT dw.dim_cliente(id_cliente, codigo_cliente, fecha_registro)
        SELECT s.IdCliente,
               LEFT(CONVERT(varchar(64), HASHBYTES('SHA2_256', CONCAT(@sal,'|',s.IdCliente)), 2), 12),
               s.FechaRegistro
        FROM staging.clientes s
        WHERE s.IdCliente <> 0 AND NOT EXISTS (SELECT 1 FROM dw.dim_cliente d WHERE d.id_cliente = s.IdCliente);

        /* ---- dim_producto (SCD tipo 2: nombre, categoria, precio_compra, precio_venta) ---- */
        -- (a) cambio en una version creada hoy: se corrige en sitio
        UPDATE d SET d.nombre = s.Nombre, d.categoria = s.Categoria,
                     d.precio_compra = s.PrecioCompra, d.precio_venta = s.PrecioVenta
        FROM dw.dim_producto d JOIN staging.productos s ON s.IdProducto = d.id_producto
        WHERE d.es_actual = 1 AND d.vigente_desde = @hoy
          AND (d.nombre <> s.Nombre OR d.categoria <> s.Categoria
               OR d.precio_compra <> s.PrecioCompra OR d.precio_venta <> s.PrecioVenta);
        -- (b) cambio en una version anterior: se cierra la vigente
        UPDATE d SET d.vigente_hasta = DATEADD(day,-1,@hoy), d.es_actual = 0
        FROM dw.dim_producto d JOIN staging.productos s ON s.IdProducto = d.id_producto
        WHERE d.es_actual = 1 AND d.vigente_desde < @hoy
          AND (d.nombre <> s.Nombre OR d.categoria <> s.Categoria
               OR d.precio_compra <> s.PrecioCompra OR d.precio_venta <> s.PrecioVenta);
        -- (c) productos nuevos o con version cerrada: se inserta la version actual
        INSERT dw.dim_producto(id_producto, nombre, categoria, precio_compra, precio_venta,
                               vigente_desde, vigente_hasta, es_actual)
        SELECT s.IdProducto, s.Nombre, s.Categoria, s.PrecioCompra, s.PrecioVenta,
               CASE WHEN EXISTS (SELECT 1 FROM dw.dim_producto x WHERE x.id_producto = s.IdProducto)
                    THEN @hoy ELSE CAST('19000101' AS date) END,
               NULL, 1
        FROM staging.productos s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_producto d WHERE d.id_producto = s.IdProducto AND d.es_actual = 1);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

---CARGA DE HECHOS 

-- fact_ventas: solo inserta lo que no existe (idempotente por id_detalle_venta)
CREATE OR ALTER PROCEDURE etl.sp_cargar_fact_ventas @id_carga INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @cli_cuar bit = (SELECT CAST(valor AS bit) FROM etl.config WHERE clave = 'cliente_nulo_cuarentena');
    DECLARE @estricto bit = CASE WHEN (SELECT valor FROM etl.config WHERE clave='politica_rechazo') = 'STRICT' THEN 1 ELSE 0 END;
    DECLARE @hoy date = CAST(GETDATE() AS date);
    DECLARE @leidas int, @rech int, @carg int;

    IF OBJECT_ID('tempdb..#v') IS NOT NULL DROP TABLE #v;
    SELECT s.IdDetalleVenta, s.IdVenta, s.Cantidad, s.PrecioUnitario,
           CAST(s.FechaVenta AS date) AS fecha,
           df.sk_fecha, dp.sk_producto, dc.sk_cliente, de.sk_empleado, dm.sk_metodo_pago,
           NULLIF(CONCAT_WS(N'; ',
               CASE WHEN ROW_NUMBER() OVER (PARTITION BY s.IdDetalleVenta ORDER BY s.IdVenta) > 1
                    THEN N'RCAL-01 duplicado' END,
               CASE WHEN s.IdDetalleVenta IS NULL OR s.IdProducto IS NULL OR s.FechaVenta IS NULL
                      OR s.Cantidad IS NULL OR s.PrecioUnitario IS NULL
                      OR (s.IdCliente IS NULL AND @cli_cuar = 1)
                    THEN N'RCAL-02 campo obligatorio nulo' END,
               CASE WHEN s.Cantidad <= 0 OR s.PrecioUnitario < 0 OR CAST(s.FechaVenta AS date) > @hoy
                    THEN N'RCAL-03 valor invalido' END,
               CASE WHEN s.IdProducto IS NOT NULL AND s.FechaVenta IS NOT NULL AND dp.sk_producto IS NULL
                    THEN N'RCAL-05 producto huerfano' END,
               CASE WHEN dc.sk_cliente IS NULL THEN N'RCAL-05 cliente huerfano' END,
               CASE WHEN de.sk_empleado IS NULL THEN N'RCAL-05 empleado huerfano' END,
               CASE WHEN s.FechaVenta IS NOT NULL AND df.sk_fecha IS NULL THEN N'RCAL-05 fecha huerfana' END,
               CASE WHEN dm.sk_metodo_pago IS NULL THEN N'RCAL-05 metodo de pago huerfano' END), N'') AS motivo
    INTO #v
    FROM staging.ventas_linea s
    LEFT JOIN dw.dim_fecha       df ON df.fecha = CAST(s.FechaVenta AS date)
    LEFT JOIN dw.dim_producto    dp ON dp.id_producto = s.IdProducto
                                   AND CAST(s.FechaVenta AS date) BETWEEN dp.vigente_desde AND ISNULL(dp.vigente_hasta,'99991231')
    LEFT JOIN dw.dim_cliente     dc ON dc.id_cliente  = ISNULL(s.IdCliente,0)
    LEFT JOIN dw.dim_empleado    de ON de.id_empleado = ISNULL(s.IdEmpleado,0)
    LEFT JOIN dw.dim_metodo_pago dm ON dm.metodo_pago = s.MetodoPago;
    SET @leidas = @@ROWCOUNT;

    INSERT etl.rechazados(id_carga, tabla_origen, clave_natural, monto, motivo)
    SELECT @id_carga, 'fact_ventas', CAST(IdDetalleVenta AS varchar(40)),
           COALESCE(Cantidad * PrecioUnitario, 0), motivo
    FROM #v WHERE motivo IS NOT NULL;
    SET @rech = @@ROWCOUNT;

    -- el subtotal se recalcula (cantidad x precio) y la diferencia queda registrada en el perfilado
    IF @estricto = 1 AND @rech > 0
        THROW 51003, 'Existen filas rechazadas en ventas (politica STRICT). Revise etl.rechazados.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT dw.fact_ventas(sk_fecha, sk_producto, sk_cliente, sk_empleado, sk_metodo_pago, id_venta,
                              id_detalle_venta, cantidad, precio_unitario, subtotal, id_carga)
        SELECT sk_fecha, sk_producto, sk_cliente, sk_empleado, sk_metodo_pago, IdVenta,
               IdDetalleVenta, Cantidad, PrecioUnitario, CAST(Cantidad * PrecioUnitario AS decimal(12,2)), @id_carga
        FROM #v v
        WHERE v.motivo IS NULL
          AND NOT EXISTS (SELECT 1 FROM dw.fact_ventas f WHERE f.id_detalle_venta = v.IdDetalleVenta);
        SET @carg = @@ROWCOUNT;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    UPDATE etl.ejecucion
       SET filas_leidas += @leidas, filas_cargadas += @carg,
           filas_existentes += (@leidas - @rech - @carg), filas_rechazadas += @rech
     WHERE id_carga = @id_carga;
END;
GO

--fact_compras: inserta lo nuevo y actualiza estado/entrega de lo existente
CREATE OR ALTER PROCEDURE etl.sp_cargar_fact_compras @id_carga INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @estricto bit = CASE WHEN (SELECT valor FROM etl.config WHERE clave='politica_rechazo') = 'STRICT' THEN 1 ELSE 0 END;
    DECLARE @hoy date = CAST(GETDATE() AS date);
    DECLARE @leidas int, @rech int, @carg int, @act int;

    IF OBJECT_ID('tempdb..#c') IS NOT NULL DROP TABLE #c;
    SELECT s.IdDetallePedido, s.IdPedido, s.Cantidad, s.PrecioUnitario,
           CAST(s.FechaPedido AS date) AS fecha_pedido, CAST(s.FechaEntrega AS date) AS fecha_entrega,
           dfp.sk_fecha AS sk_fecha_pedido, ISNULL(dfe.sk_fecha, 0) AS sk_fecha_entrega,
           dp.sk_producto, dv.sk_proveedor, ISNULL(de.sk_estado, 0) AS sk_estado,
           CASE WHEN s.FechaEntrega IS NULL THEN NULL
                ELSE DATEDIFF(day, CAST(s.FechaPedido AS date), CAST(s.FechaEntrega AS date)) END AS dias_entrega,
           NULLIF(CONCAT_WS(N'; ',
               CASE WHEN ROW_NUMBER() OVER (PARTITION BY s.IdDetallePedido ORDER BY s.IdPedido) > 1
                    THEN N'RCAL-01 duplicado' END,
               CASE WHEN s.IdDetallePedido IS NULL OR s.IdProducto IS NULL OR s.FechaPedido IS NULL
                      OR s.Cantidad IS NULL OR s.PrecioUnitario IS NULL OR s.IdProveedor IS NULL
                    THEN N'RCAL-02 campo obligatorio nulo' END,
               CASE WHEN s.Cantidad <= 0 OR s.PrecioUnitario < 0 OR CAST(s.FechaPedido AS date) > @hoy
                      OR s.FechaEntrega < s.FechaPedido
                    THEN N'RCAL-03 valor invalido' END,
               CASE WHEN s.IdProducto IS NOT NULL AND s.FechaPedido IS NOT NULL AND dp.sk_producto IS NULL
                    THEN N'RCAL-05 producto huerfano' END,
               CASE WHEN s.IdProveedor IS NOT NULL AND dv.sk_proveedor IS NULL THEN N'RCAL-05 proveedor huerfano' END,
               CASE WHEN s.FechaPedido IS NOT NULL AND dfp.sk_fecha IS NULL THEN N'RCAL-05 fecha de pedido huerfana' END,
               CASE WHEN s.FechaEntrega IS NOT NULL AND dfe.sk_fecha IS NULL THEN N'RCAL-05 fecha de entrega huerfana' END,
               CASE WHEN s.IdEstado IS NOT NULL AND de.sk_estado IS NULL THEN N'RCAL-05 estado huerfano' END), N'') AS motivo
    INTO #c
    FROM staging.compras_linea s
    LEFT JOIN dw.dim_fecha         dfp ON dfp.fecha = CAST(s.FechaPedido AS date)
    LEFT JOIN dw.dim_fecha         dfe ON dfe.fecha = CAST(s.FechaEntrega AS date)
    LEFT JOIN dw.dim_producto      dp  ON dp.id_producto = s.IdProducto
                                      AND CAST(s.FechaPedido AS date) BETWEEN dp.vigente_desde AND ISNULL(dp.vigente_hasta,'99991231')
    LEFT JOIN dw.dim_proveedor     dv  ON dv.id_proveedor = s.IdProveedor
    LEFT JOIN dw.dim_estado_pedido de  ON de.id_estado = s.IdEstado;
    SET @leidas = @@ROWCOUNT;

    INSERT etl.rechazados(id_carga, tabla_origen, clave_natural, monto, motivo)
    SELECT @id_carga, 'fact_compras', CAST(IdDetallePedido AS varchar(40)),
           COALESCE(Cantidad * PrecioUnitario, 0), motivo
    FROM #c WHERE motivo IS NOT NULL;
    SET @rech = @@ROWCOUNT;

    IF @estricto = 1 AND @rech > 0
        THROW 51013, 'Existen filas rechazadas en compras (politica STRICT). Revise etl.rechazados.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        -- el estado y la entrega cambian con el tiempo: se actualizan
        UPDATE f SET f.sk_estado = c.sk_estado, f.sk_fecha_entrega = c.sk_fecha_entrega,
                     f.dias_entrega = c.dias_entrega, f.cantidad = c.Cantidad,
                     f.precio_compra = c.PrecioUnitario,
                     f.subtotal = CAST(c.Cantidad * c.PrecioUnitario AS decimal(12,2)), f.id_carga = @id_carga
        FROM dw.fact_compras f
        JOIN #c c ON c.IdDetallePedido = f.id_detalle_pedido AND c.motivo IS NULL
        WHERE f.sk_estado <> c.sk_estado OR f.sk_fecha_entrega <> c.sk_fecha_entrega
           OR ISNULL(f.dias_entrega,-1) <> ISNULL(c.dias_entrega,-1)
           OR f.cantidad <> c.Cantidad OR f.precio_compra <> c.PrecioUnitario;
        SET @act = @@ROWCOUNT;

        INSERT dw.fact_compras(sk_fecha_pedido, sk_fecha_entrega, sk_producto, sk_proveedor, sk_estado,
                               id_pedido, id_detalle_pedido, cantidad, precio_compra, subtotal,
                               dias_entrega, id_carga)
        SELECT sk_fecha_pedido, sk_fecha_entrega, sk_producto, sk_proveedor, sk_estado,
               IdPedido, IdDetallePedido, Cantidad, PrecioUnitario,
               CAST(Cantidad * PrecioUnitario AS decimal(12,2)), dias_entrega, @id_carga
        FROM #c c
        WHERE c.motivo IS NULL
          AND NOT EXISTS (SELECT 1 FROM dw.fact_compras f WHERE f.id_detalle_pedido = c.IdDetallePedido);
        SET @carg = @@ROWCOUNT;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    UPDATE etl.ejecucion
       SET filas_leidas += @leidas, filas_cargadas += @carg, filas_actualizadas += @act,
           filas_existentes += (@leidas - @rech - @carg), filas_rechazadas += @rech
     WHERE id_carga = @id_carga;
END;
GO

--fact_inventario: foto al cierre del dia (rehace solo la de hoy; conserva el historial)
CREATE OR ALTER PROCEDURE etl.sp_cargar_fact_inventario @id_carga INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @sk int = CONVERT(int, CONVERT(char(8), GETDATE(), 112));
    IF NOT EXISTS (SELECT 1 FROM dw.dim_fecha WHERE sk_fecha = @sk)
        THROW 51021, 'La fecha de hoy no existe en dim_fecha. Ejecute antes etl.sp_cargar_dimensiones.', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM dw.fact_inventario WHERE sk_fecha = @sk;
        INSERT dw.fact_inventario(sk_fecha, sk_producto, stock_cierre, stock_minimo,
                                  valor_inventario, bajo_minimo, id_carga)
        SELECT @sk, dp.sk_producto, s.Stock, s.StockMinimo,
               CAST(s.Stock * s.PrecioCompra AS decimal(14,2)),
               CASE WHEN s.Stock < s.StockMinimo THEN 1 ELSE 0 END, @id_carga
        FROM staging.productos s
        JOIN dw.dim_producto dp ON dp.id_producto = s.IdProducto AND dp.es_actual = 1;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

---VALIDACION
CREATE OR ALTER PROCEDURE etl.sp_validar @id_carga INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @umbral decimal(9,4) = (SELECT CAST(valor AS decimal(9,4)) FROM etl.config WHERE clave='umbral_rechazo_pct');

    -- Ventas: filas e importe esperados = staging - rechazados; reales = hechos con clave presente en staging
    DECLARE @vs bigint = (SELECT COUNT_BIG(*) FROM staging.ventas_linea);
    DECLARE @vr bigint = (SELECT COUNT_BIG(*) FROM etl.rechazados WHERE id_carga=@id_carga AND tabla_origen='fact_ventas');
    DECLARE @vm decimal(19,4) = (SELECT COALESCE(SUM(Cantidad*PrecioUnitario),0) FROM staging.ventas_linea)
                              - (SELECT COALESCE(SUM(monto),0) FROM etl.rechazados WHERE id_carga=@id_carga AND tabla_origen='fact_ventas');
    DECLARE @vf bigint = (SELECT COUNT_BIG(*) FROM dw.fact_ventas f
                          WHERE EXISTS (SELECT 1 FROM staging.ventas_linea s WHERE s.IdDetalleVenta = f.id_detalle_venta));
    DECLARE @vfm decimal(19,4) = (SELECT COALESCE(SUM(f.subtotal),0) FROM dw.fact_ventas f
                          WHERE EXISTS (SELECT 1 FROM staging.ventas_linea s WHERE s.IdDetalleVenta = f.id_detalle_venta));
    -- Compras
    DECLARE @cs bigint = (SELECT COUNT_BIG(*) FROM staging.compras_linea);
    DECLARE @cr bigint = (SELECT COUNT_BIG(*) FROM etl.rechazados WHERE id_carga=@id_carga AND tabla_origen='fact_compras');
    DECLARE @cm decimal(19,4) = (SELECT COALESCE(SUM(Cantidad*PrecioUnitario),0) FROM staging.compras_linea)
                              - (SELECT COALESCE(SUM(monto),0) FROM etl.rechazados WHERE id_carga=@id_carga AND tabla_origen='fact_compras');
    DECLARE @cf bigint = (SELECT COUNT_BIG(*) FROM dw.fact_compras f
                          WHERE EXISTS (SELECT 1 FROM staging.compras_linea s WHERE s.IdDetallePedido = f.id_detalle_pedido));
    DECLARE @cfm decimal(19,4) = (SELECT COALESCE(SUM(f.subtotal),0) FROM dw.fact_compras f
                          WHERE EXISTS (SELECT 1 FROM staging.compras_linea s WHERE s.IdDetallePedido = f.id_detalle_pedido));
    -- Inventario
    DECLARE @sk int = CONVERT(int, CONVERT(char(8), GETDATE(), 112));
    DECLARE @is bigint = (SELECT COUNT_BIG(*) FROM staging.productos);
    DECLARE @if bigint = (SELECT COUNT_BIG(*) FROM dw.fact_inventario WHERE sk_fecha = @sk);
    -- RCAL-06 privacidad: dim_cliente no debe tener columnas con datos personales
    DECLARE @pii int = (SELECT COUNT(*) FROM sys.columns
                        WHERE object_id = OBJECT_ID('dw.dim_cliente')
                          AND name IN ('nombre','telefono','celular','direccion','correo','email'));

    INSERT etl.perfilado(id_carga, tabla, metrica, valor)
    SELECT @id_carga,'dw','columnas_con_datos_personales', @pii UNION ALL
    SELECT @id_carga,'fact_ventas','rechazados', @vr UNION ALL
    SELECT @id_carga,'fact_compras','rechazados', @cr;

    IF @vs - @vr <> @vf          THROW 51004, 'No cuadran las filas de staging y fact_ventas.', 1;
    IF ABS(@vm - @vfm) > 0.01    THROW 51005, 'No cuadra el importe de ventas.', 1;
    IF @cs - @cr <> @cf          THROW 51014, 'No cuadran las filas de staging y fact_compras.', 1;
    IF ABS(@cm - @cfm) > 0.01    THROW 51015, 'No cuadra el importe de compras.', 1;
    IF @is <> @if                THROW 51022, 'No cuadra la foto de inventario del dia.', 1;
    IF @pii > 0                  THROW 51030, 'dim_cliente contiene columnas con datos personales (RCAL-06).', 1;

    DECLARE @pct decimal(9,4) = CASE WHEN (@vs + @cs) = 0 THEN 0 ELSE 100.0 * (@vr + @cr) / (@vs + @cs) END;
    INSERT etl.perfilado(id_carga, tabla, metrica, valor) VALUES (@id_carga,'dw','pct_rechazo', @pct);
    IF @pct > @umbral
        UPDATE etl.ejecucion SET estado = 'ADVERTENCIA',
               mensaje = CONCAT('Rechazo de ', CAST(@pct AS varchar(20)), '% supera el umbral de ', CAST(@umbral AS varchar(20)), '%')
        WHERE id_carga = @id_carga;

    SELECT 'fact_ventas' AS hecho, @vs AS filas_staging, @vr AS rechazadas, @vf AS filas_hecho,
           @vm AS importe_esperado, @vfm AS importe_hecho, N'VALIDACION CORRECTA' AS resultado
    UNION ALL SELECT 'fact_compras', @cs, @cr, @cf, @cm, @cfm, N'VALIDACION CORRECTA'
    UNION ALL SELECT 'fact_inventario (hoy)', @is, 0, @if, NULL, NULL, N'VALIDACION CORRECTA';
END;
GO

-- Conciliacion mensual dbo vs dw (diferencia esperada = filas rechazadas de ese mes)
CREATE OR ALTER PROCEDURE etl.sp_reconciliar
AS
BEGIN
    SET NOCOUNT ON;
    SELECT COALESCE(o.ym, w.ym) AS anio_mes,
           o.filas AS filas_oltp, w.filas AS filas_dw, o.filas - ISNULL(w.filas,0) AS dif_filas,
           o.importe AS importe_oltp, w.importe AS importe_dw, o.importe - ISNULL(w.importe,0) AS dif_importe
    FROM (SELECT LEFT(CONVERT(char(10), CAST(v.FechaVenta AS date), 23), 7) AS ym, COUNT(*) AS filas,
                 SUM(d.Cantidad * d.PrecioUnitario) AS importe
          FROM Panaderia.dbo.DetalleVenta d JOIN Panaderia.dbo.Ventas v ON v.IdVenta = d.IdVenta
          GROUP BY LEFT(CONVERT(char(10), CAST(v.FechaVenta AS date), 23), 7)) o
    FULL OUTER JOIN
         (SELECT LEFT(CONVERT(char(10), df.fecha, 23), 7) AS ym, COUNT(*) AS filas, SUM(f.subtotal) AS importe
          FROM dw.fact_ventas f JOIN dw.dim_fecha df ON df.sk_fecha = f.sk_fecha
          GROUP BY LEFT(CONVERT(char(10), df.fecha, 23), 7)) w ON w.ym = o.ym
    ORDER BY 1;
END;
GO

--- ETL Y ELT

-- ETL: extrae (copia tipada) -> perfila -> limpia/valida -> carga dimensiones y luego hechos
CREATE OR ALTER PROCEDURE etl.sp_etl_maestro
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id int;
    INSERT etl.ejecucion(tipo, inicio, estado) VALUES ('ETL', SYSDATETIME(), 'EN CURSO');
    SET @id = SCOPE_IDENTITY();
    BEGIN TRY
        EXEC etl.sp_extraer_dimensiones @id;
        EXEC etl.sp_extraer_hechos      @id;
        EXEC etl.sp_perfilar            @id;
        EXEC etl.sp_cargar_dimensiones  @id;     -- primero dimensiones
        EXEC etl.sp_cargar_fact_ventas  @id;     -- despues hechos
        EXEC etl.sp_cargar_fact_compras @id;
        EXEC etl.sp_cargar_fact_inventario @id;
        EXEC etl.sp_validar             @id;
        UPDATE etl.ejecucion SET estado = 'OK' WHERE id_carga = @id AND estado = 'EN CURSO';
        UPDATE etl.ejecucion SET fin = SYSDATETIME() WHERE id_carga = @id;
    END TRY
    BEGIN CATCH
        UPDATE etl.ejecucion SET estado = 'ERROR', fin = SYSDATETIME(), mensaje = LEFT(ERROR_MESSAGE(),500)
        WHERE id_carga = @id;
        THROW;
    END CATCH
END;
GO

--  ELT: L = carga cruda en texto (elt.raw_*)   T = transformacion dentro del motor (TRY_CAST)

CREATE OR ALTER PROCEDURE elt.sp_elt_cargar_raw
    @id_carga INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM elt.raw_ventas_linea
    WHERE archivo = 'dbo';

    DELETE FROM elt.raw_compras_linea
    WHERE archivo = 'dbo';

    -- Carga cruda de ventas
    INSERT INTO elt.raw_ventas_linea
    (
        id_carga, archivo, IdDetalleVenta, IdVenta, IdProducto,
        Cantidad, PrecioUnitario, Subtotal, FechaVenta,
        IdCliente, IdEmpleado, MetodoPago
    )
    SELECT
        @id_carga,
        'dbo',
        CAST(d.IdDetalle AS nvarchar(50)),
        CAST(d.IdVenta AS nvarchar(50)),
        CAST(d.IdProducto AS nvarchar(50)),
        CAST(d.Cantidad AS nvarchar(50)),
        CAST(d.PrecioUnitario AS nvarchar(50)),
        CAST(d.Subtotal AS nvarchar(50)),
        CONVERT(nvarchar(50), v.FechaVenta, 126),
        CAST(v.IdCliente AS nvarchar(50)),
        CAST(v.IdEmpleado AS nvarchar(50)),
        CAST(v.MetodoPago AS nvarchar(50))
    FROM Panaderia.dbo.DetalleVenta AS d
    LEFT JOIN Panaderia.dbo.Ventas AS v
        ON v.IdVenta = d.IdVenta;

    -- Carga cruda de compras
    INSERT INTO elt.raw_compras_linea
    (
        id_carga, archivo, IdDetallePedido, IdPedido, IdProducto,
        Cantidad, PrecioUnitario, Subtotal, FechaPedido,
        FechaEntrega, IdProveedor, IdEstado
    )
    SELECT
        @id_carga,
        'dbo',
        CAST(d.IdDetallePedido AS nvarchar(50)),
        CAST(d.IdPedido AS nvarchar(50)),
        CAST(d.IdProducto AS nvarchar(50)),
        CAST(d.Cantidad AS nvarchar(50)),
        CAST(d.PrecioCompra AS nvarchar(50)),
        CAST(d.Subtotal AS nvarchar(50)),
        CONVERT(nvarchar(50), h.FechaPedido, 126),
        CONVERT(nvarchar(50), h.FechaEntrega, 126),
        CAST(h.IdProveedor AS nvarchar(50)),
        CAST(h.IdEstado AS nvarchar(50))
    FROM Panaderia.dbo.DetallePedido AS d
    LEFT JOIN Panaderia.dbo.PedidosProveedor AS h
        ON h.IdPedido = d.IdPedido;
END;
GO


CREATE OR ALTER PROCEDURE elt.sp_elt_transformar @id_carga INT
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE staging.ventas_linea;
    TRUNCATE TABLE staging.compras_linea;
    -- NULLIF(...,'') evita que '' se convierta en 0; la coma decimal se normaliza a punto
    INSERT staging.ventas_linea(id_carga, IdDetalleVenta, IdVenta, IdProducto, Cantidad, PrecioUnitario,
                                Subtotal, FechaVenta, IdCliente, IdEmpleado, MetodoPago)
    SELECT @id_carga,
           TRY_CAST(NULLIF(LTRIM(RTRIM(IdDetalleVenta)),'') AS int),
           TRY_CAST(NULLIF(LTRIM(RTRIM(IdVenta)),'') AS int),
           TRY_CAST(NULLIF(LTRIM(RTRIM(IdProducto)),'') AS int),
           TRY_CAST(NULLIF(LTRIM(RTRIM(Cantidad)),'') AS int),
           TRY_CAST(REPLACE(NULLIF(LTRIM(RTRIM(PrecioUnitario)),''), ',', '.') AS decimal(12,2)),
           TRY_CAST(REPLACE(NULLIF(LTRIM(RTRIM(Subtotal)),''), ',', '.') AS decimal(12,2)),
           TRY_CAST(NULLIF(LTRIM(RTRIM(FechaVenta)),'') AS datetime),
           TRY_CAST(NULLIF(LTRIM(RTRIM(IdCliente)),'') AS int),
           TRY_CAST(NULLIF(LTRIM(RTRIM(IdEmpleado)),'') AS int),
           COALESCE(NULLIF(LTRIM(RTRIM(MetodoPago)),''), 'NO ESPECIFICADO')
    FROM elt.raw_ventas_linea WHERE id_carga = @id_carga;

    INSERT staging.compras_linea(id_carga, IdDetallePedido, IdPedido, IdProducto, Cantidad, PrecioUnitario,
                                 Subtotal, FechaPedido, FechaEntrega, IdProveedor, IdEstado)
    SELECT @id_carga,
           TRY_CAST(NULLIF(LTRIM(RTRIM(IdDetallePedido)),'') AS int),
           TRY_CAST(NULLIF(LTRIM(RTRIM(IdPedido)),'') AS int),
           TRY_CAST(NULLIF(LTRIM(RTRIM(IdProducto)),'') AS int),
           TRY_CAST(NULLIF(LTRIM(RTRIM(Cantidad)),'') AS int),
           TRY_CAST(REPLACE(NULLIF(LTRIM(RTRIM(PrecioUnitario)),''), ',', '.') AS decimal(12,2)),
           TRY_CAST(REPLACE(NULLIF(LTRIM(RTRIM(Subtotal)),''), ',', '.') AS decimal(12,2)),
           TRY_CAST(NULLIF(LTRIM(RTRIM(FechaPedido)),'') AS datetime),
           TRY_CAST(NULLIF(LTRIM(RTRIM(FechaEntrega)),'') AS datetime),
           TRY_CAST(NULLIF(LTRIM(RTRIM(IdProveedor)),'') AS int),
           TRY_CAST(NULLIF(LTRIM(RTRIM(IdEstado)),'') AS int)
    FROM elt.raw_compras_linea WHERE id_carga = @id_carga;
END;
GO

CREATE OR ALTER PROCEDURE elt.sp_elt_maestro
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id int;
    INSERT etl.ejecucion(tipo, inicio, estado) VALUES ('ELT', SYSDATETIME(), 'EN CURSO');
    SET @id = SCOPE_IDENTITY();
    BEGIN TRY
        EXEC etl.sp_extraer_dimensiones @id;
        EXEC elt.sp_elt_cargar_raw      @id;     -- L: cargar crudo
        EXEC elt.sp_elt_transformar     @id;     -- T: transformar en el motor
        EXEC etl.sp_perfilar            @id;
        EXEC etl.sp_cargar_dimensiones  @id;
        EXEC etl.sp_cargar_fact_ventas  @id;
        EXEC etl.sp_cargar_fact_compras @id;
        EXEC etl.sp_cargar_fact_inventario @id;
        EXEC etl.sp_validar             @id;
        UPDATE etl.ejecucion SET estado = 'OK' WHERE id_carga = @id AND estado = 'EN CURSO';
        UPDATE etl.ejecucion SET fin = SYSDATETIME() WHERE id_carga = @id;
    END TRY
    BEGIN CATCH
        UPDATE etl.ejecucion SET estado = 'ERROR', fin = SYSDATETIME(), mensaje = LEFT(ERROR_MESSAGE(),500)
        WHERE id_carga = @id;
        THROW;
    END CATCH
END;
GO

----VISTAS Y SEGURIDAD PARA POWER BI 
CREATE OR ALTER VIEW dw.vw_ventas_mes AS
SELECT d.anio, d.mes, d.nombre_mes, p.id_producto, p.nombre AS producto, p.categoria,
       mp.tipo_pago, SUM(f.cantidad) AS unidades, SUM(f.subtotal) AS importe,
       COUNT(DISTINCT f.id_venta) AS n_ventas
FROM dw.fact_ventas f
JOIN dw.dim_fecha d          ON d.sk_fecha = f.sk_fecha
JOIN dw.dim_producto p       ON p.sk_producto = f.sk_producto
JOIN dw.dim_metodo_pago mp   ON mp.sk_metodo_pago = f.sk_metodo_pago
GROUP BY d.anio, d.mes, d.nombre_mes, p.id_producto, p.nombre, p.categoria, mp.tipo_pago;
GO
CREATE OR ALTER VIEW dw.vw_ventas_detalle AS
SELECT d.fecha, d.anio, d.mes, d.nombre_dia, p.nombre AS producto, p.categoria,
       c.codigo_cliente, e.nombre AS empleado, mp.metodo_pago, mp.tipo_pago,
       f.id_venta, f.cantidad, f.precio_unitario, f.subtotal
FROM dw.fact_ventas f
JOIN dw.dim_fecha d        ON d.sk_fecha = f.sk_fecha
JOIN dw.dim_producto p     ON p.sk_producto = f.sk_producto
JOIN dw.dim_cliente c      ON c.sk_cliente = f.sk_cliente
JOIN dw.dim_empleado e     ON e.sk_empleado = f.sk_empleado
JOIN dw.dim_metodo_pago mp ON mp.sk_metodo_pago = f.sk_metodo_pago;
GO
CREATE OR ALTER VIEW dw.vw_inventario_stock AS
SELECT d.fecha, p.nombre AS producto, p.categoria, i.stock_cierre, i.stock_minimo,
       i.valor_inventario, i.bajo_minimo
FROM dw.fact_inventario i
JOIN dw.dim_fecha d    ON d.sk_fecha = i.sk_fecha
JOIN dw.dim_producto p ON p.sk_producto = i.sk_producto;
GO
CREATE OR ALTER VIEW dw.vw_pedidos_estado AS
SELECT d.anio, d.mes, pr.nombre AS proveedor, e.estado,
       COUNT(DISTINCT f.id_pedido) AS pedidos, SUM(f.cantidad) AS unidades, SUM(f.subtotal) AS importe
FROM dw.fact_compras f
JOIN dw.dim_fecha d           ON d.sk_fecha = f.sk_fecha_pedido
JOIN dw.dim_proveedor pr      ON pr.sk_proveedor = f.sk_proveedor
JOIN dw.dim_estado_pedido e   ON e.sk_estado = f.sk_estado
GROUP BY d.anio, d.mes, pr.nombre, e.estado;
GO
CREATE OR ALTER VIEW dw.vw_compras_entrega AS
SELECT dp.fecha AS fecha_pedido, de.fecha AS fecha_entrega, pr.nombre AS proveedor,
       p.nombre AS producto, e.estado, f.cantidad, f.precio_compra, f.subtotal, f.dias_entrega
FROM dw.fact_compras f
JOIN dw.dim_fecha dp          ON dp.sk_fecha = f.sk_fecha_pedido
JOIN dw.dim_fecha de          ON de.sk_fecha = f.sk_fecha_entrega
JOIN dw.dim_proveedor pr      ON pr.sk_proveedor = f.sk_proveedor
JOIN dw.dim_producto p        ON p.sk_producto = f.sk_producto
JOIN dw.dim_estado_pedido e   ON e.sk_estado = f.sk_estado;
GO
IF DATABASE_PRINCIPAL_ID('rol_bi') IS NULL CREATE ROLE rol_bi;
GRANT SELECT ON dw.vw_ventas_mes       TO rol_bi;
GRANT SELECT ON dw.vw_ventas_detalle   TO rol_bi;
GRANT SELECT ON dw.vw_inventario_stock TO rol_bi;
GRANT SELECT ON dw.vw_pedidos_estado   TO rol_bi;
GRANT SELECT ON dw.vw_compras_entrega  TO rol_bi;
GO

/*  SQL Server Express no incluye SQL Server Agent. Para la carga nocturna usa el
   Programador de tareas de Windows:
   sqlcmd -S . -d DW_Panaderia -Q "EXEC etl.sp_etl_maestro*/