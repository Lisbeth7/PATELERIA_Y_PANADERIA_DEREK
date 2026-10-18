
-- DATAMART------------
IF DB_ID('DW_Panaderia') IS NULL CREATE DATABASE DW_Panaderia;
GO

ALTER DATABASE DW_Panaderia SET RECOVERY SIMPLE;
GO

USE DW_Panaderia;
GO
IF SCHEMA_ID('dw')      IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('staging') IS NULL EXEC('CREATE SCHEMA staging');
IF SCHEMA_ID('etl')     IS NULL EXEC('CREATE SCHEMA etl');
IF SCHEMA_ID('elt')     IS NULL EXEC('CREATE SCHEMA elt');
GO


----1. MODELO FISICO (ESTRELLA)
IF OBJECT_ID('dw.dim_fecha','U') IS NULL
CREATE TABLE dw.dim_fecha(
    sk_fecha       INT         NOT NULL CONSTRAINT PK_dim_fecha PRIMARY KEY,
    fecha          DATE        NOT NULL CONSTRAINT UQ_dim_fecha UNIQUE,
    anio           SMALLINT    NOT NULL,
    trimestre      TINYINT     NOT NULL,
    mes            TINYINT     NOT NULL,
    nombre_mes     VARCHAR(12) NOT NULL,
    dia            TINYINT     NOT NULL,
    dia_semana     TINYINT     NOT NULL,            -- 1 = Lunes ... 7 = Domingo
    nombre_dia     VARCHAR(12) NOT NULL,           
    es_fin_semana  BIT         NOT NULL
);
-- dim_producto 
IF OBJECT_ID('dw.dim_producto','U') IS NULL
CREATE TABLE dw.dim_producto(
    sk_producto   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_producto PRIMARY KEY,
    id_producto   INT           NOT NULL,           
    nombre        VARCHAR(150)  NOT NULL,
    categoria     VARCHAR(100)  NOT NULL,
    precio_compra DECIMAL(10,2) NOT NULL,
    precio_venta  DECIMAL(10,2) NOT NULL,
    vigente_desde DATE          NOT NULL,
    vigente_hasta DATE          NULL,              
    es_actual     BIT           NOT NULL,
    CONSTRAINT UQ_dim_producto UNIQUE (id_producto, vigente_desde)
);
-- dim_cliente 
IF OBJECT_ID('dw.dim_cliente','U') IS NULL
CREATE TABLE dw.dim_cliente(
    sk_cliente      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_cliente PRIMARY KEY,
    id_cliente      INT         NOT NULL CONSTRAINT UQ_dim_cliente UNIQUE,     
    codigo_cliente  VARCHAR(12) NOT NULL,                                        
    fecha_registro  DATE        NULL
);

--  dim_empleado 
IF OBJECT_ID('dw.dim_empleado','U') IS NULL
CREATE TABLE dw.dim_empleado(
    sk_empleado INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_empleado PRIMARY KEY,
    id_empleado INT          NOT NULL CONSTRAINT UQ_dim_empleado UNIQUE,        
    nombre      VARCHAR(150) NOT NULL,
    cargo       VARCHAR(100) NOT NULL
);

--dim_metodo_pago (estatica: efectivo, billetera digital, tarjeta)
IF OBJECT_ID('dw.dim_metodo_pago','U') IS NULL
CREATE TABLE dw.dim_metodo_pago(
    sk_metodo_pago INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_metodo_pago PRIMARY KEY,
    metodo_pago    VARCHAR(50) NOT NULL CONSTRAINT UQ_dim_metodo_pago UNIQUE,   
    tipo_pago      VARCHAR(30) NOT NULL
);

--dim_proveedor 
IF OBJECT_ID('dw.dim_proveedor','U') IS NULL
CREATE TABLE dw.dim_proveedor(
    sk_proveedor INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_proveedor PRIMARY KEY,
    id_proveedor INT          NOT NULL CONSTRAINT UQ_dim_proveedor UNIQUE,      
    ruc          VARCHAR(20)  NULL,
    nombre       VARCHAR(150) NOT NULL
);

--dim_estado_pedido (estatica: pendiente, recibido, cancelado)
IF OBJECT_ID('dw.dim_estado_pedido','U') IS NULL
CREATE TABLE dw.dim_estado_pedido(
    sk_estado INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_estado_pedido PRIMARY KEY,
    id_estado INT         NOT NULL CONSTRAINT UQ_dim_estado_pedido UNIQUE,     
    estado    VARCHAR(60) NOT NULL
);

-- fact_ventas 
IF OBJECT_ID('dw.fact_ventas','U') IS NULL
CREATE TABLE dw.fact_ventas(
    sk_venta         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_fact_ventas PRIMARY KEY,
    sk_fecha         INT NOT NULL CONSTRAINT FK_fv_fecha    FOREIGN KEY REFERENCES dw.dim_fecha(sk_fecha),
    sk_producto      INT NOT NULL CONSTRAINT FK_fv_producto FOREIGN KEY REFERENCES dw.dim_producto(sk_producto),
    sk_cliente       INT NOT NULL CONSTRAINT FK_fv_cliente  FOREIGN KEY REFERENCES dw.dim_cliente(sk_cliente),
    sk_empleado      INT NOT NULL CONSTRAINT FK_fv_empleado FOREIGN KEY REFERENCES dw.dim_empleado(sk_empleado),
    sk_metodo_pago   INT NOT NULL CONSTRAINT FK_fv_pago     FOREIGN KEY REFERENCES dw.dim_metodo_pago(sk_metodo_pago),
    id_venta         INT NOT NULL,
    id_detalle_venta INT NOT NULL CONSTRAINT UQ_fv_detalle UNIQUE,              -- clave natural unica
    cantidad         INT           NOT NULL CONSTRAINT CK_fv_cantidad CHECK (cantidad > 0),
    precio_unitario  DECIMAL(10,2) NOT NULL CONSTRAINT CK_fv_precio   CHECK (precio_unitario >= 0),
    subtotal         DECIMAL(12,2) NOT NULL,                                     -- cantidad x precio_unitario
    id_carga         INT NOT NULL
);

-- fact_compras
IF OBJECT_ID('dw.fact_compras','U') IS NULL
CREATE TABLE dw.fact_compras(
    sk_compra          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_fact_compras PRIMARY KEY,
    sk_fecha_pedido    INT NOT NULL CONSTRAINT FK_fc_fecha_pedido  FOREIGN KEY REFERENCES dw.dim_fecha(sk_fecha),
    sk_fecha_entrega   INT NOT NULL CONSTRAINT FK_fc_fecha_entrega FOREIGN KEY REFERENCES dw.dim_fecha(sk_fecha), -- 0 = sin entrega
    sk_producto        INT NOT NULL CONSTRAINT FK_fc_producto  FOREIGN KEY REFERENCES dw.dim_producto(sk_producto),
    sk_proveedor       INT NOT NULL CONSTRAINT FK_fc_proveedor FOREIGN KEY REFERENCES dw.dim_proveedor(sk_proveedor),
    sk_estado          INT NOT NULL CONSTRAINT FK_fc_estado    FOREIGN KEY REFERENCES dw.dim_estado_pedido(sk_estado),
    id_pedido          INT NOT NULL,
    id_detalle_pedido  INT NOT NULL CONSTRAINT UQ_fc_detalle UNIQUE,     
    cantidad           INT           NOT NULL CONSTRAINT CK_fc_cantidad CHECK (cantidad > 0),
    precio_compra      DECIMAL(10,2) NOT NULL CONSTRAINT CK_fc_precio   CHECK (precio_compra >= 0),
    subtotal           DECIMAL(12,2) NOT NULL,
    dias_entrega       INT NULL,   -- NULL = aun no entregado
    id_carga           INT NOT NULL
);

-- fact_inventario 
IF OBJECT_ID('dw.fact_inventario','U') IS NULL
CREATE TABLE dw.fact_inventario(
    sk_fecha          INT NOT NULL CONSTRAINT FK_fi_fecha    FOREIGN KEY REFERENCES dw.dim_fecha(sk_fecha),
    sk_producto       INT NOT NULL CONSTRAINT FK_fi_producto FOREIGN KEY REFERENCES dw.dim_producto(sk_producto),
    stock_cierre      INT           NOT NULL,
    stock_minimo      INT           NOT NULL,
    valor_inventario  DECIMAL(14,2) NOT NULL,  -- stock_cierre x precio_compra
    bajo_minimo       BIT           NOT NULL,   -- 1 = stock < minimo
    id_carga          INT NOT NULL,
    CONSTRAINT PK_fact_inventario PRIMARY KEY (sk_fecha, sk_producto)
);
GO