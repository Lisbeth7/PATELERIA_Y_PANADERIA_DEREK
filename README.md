# E-15. Validación del modelo semántico

Consulta DAX de solo lectura para comprobar conteos y controles de calidad del modelo semántico `Model`, abierto en Power BI Desktop.

## Archivos

- `E-15_validacion_modelo_powerbi.dax`: consulta de validación.
- `resultado_E-15.csv`: resultado agregado de la ejecución registrada.
- `captura_E-15.png`: representación visual del resultado; no es una captura de DAX Studio.
- `registro_ejecucion.md`: entorno, procedencia y alcance de la ejecución.
- `resultados_referencia.md`: valores observados y alcance de los controles.

La prueba no modifica ni actualiza el modelo. Es una validación funcional; no sustituye EXP-01 (SQL 3FN frente a modelo estrella) ni EXP-02 (ETL frente a ELT). Una ejecución aislada no representa p95 ni throughput.
