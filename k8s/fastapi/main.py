import os
import re
import uuid
from decimal import Decimal
from typing import Any

import boto3
from fastapi import FastAPI, HTTPException
from pydantic import AliasChoices, BaseModel, ConfigDict, Field, field_validator

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
PRODUCTOS_TABLE = os.getenv("PRODUCTOS_TABLE", "dev-productos")
CLIENTES_TABLE = os.getenv("CLIENTES_TABLE", "dev-clientes")

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
productos_table = dynamodb.Table(PRODUCTOS_TABLE)
clientes_table = dynamodb.Table(CLIENTES_TABLE)

app = FastAPI(title="API Supermercado", version="1.0.0")


class ProductoIn(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    nombre: str = Field(
        min_length=1,
        validation_alias=AliasChoices("nombre", "Nombre", "name"),
    )
    precio: float = Field(
        gt=0,
        validation_alias=AliasChoices("precio", "Precio", "price"),
    )
    stock: int = Field(
        ge=0,
        validation_alias=AliasChoices("stock", "Stock", "cantidad", "quantity"),
    )

    @field_validator("precio", mode="before")
    @classmethod
    def coerce_precio(cls, value: Any) -> Any:
        if isinstance(value, str):
            value = value.strip().replace(",", ".")
        return value

    @field_validator("stock", mode="before")
    @classmethod
    def coerce_stock(cls, value: Any) -> Any:
        if isinstance(value, str):
            return int(value.strip())
        return value


class ProductoOut(ProductoIn):
    productoId: str


def _producto_item_for_response(item: dict[str, Any]) -> dict[str, Any]:
    data = _decimal_to_float(dict(item))
    pid = data.pop("producto_id", None) or data.get("productoId")
    nombre = data.get("nombre") or data.get("Nombre") or data.get("name")
    precio = data.get("precio") if data.get("precio") is not None else data.get("Precio", data.get("price"))
    stock = data.get("stock") if data.get("stock") is not None else data.get("Stock", data.get("cantidad", data.get("quantity")))
    if pid is None or nombre is None or precio is None or stock is None:
        raise HTTPException(status_code=500, detail="Registro de producto incompleto en DynamoDB")
    return {
        "productoId": str(pid),
        "nombre": str(nombre),
        "precio": float(precio),
        "stock": int(stock),
    }


def _normalize_fecha_nacimiento(value: str) -> str:
    value = value.strip()
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return value
    m = re.fullmatch(r"(\d{1,2})/(\d{1,2})/(\d{4})", value)
    if m:
        day, month, year = int(m.group(1)), int(m.group(2)), int(m.group(3))
        return f"{year:04d}-{month:02d}-{day:02d}"
    raise ValueError("fechaNacimiento debe ser YYYY-MM-DD o DD/MM/YYYY")


class ClienteIn(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    nombre: str = Field(min_length=1)
    fechaNacimiento: str = Field(
        validation_alias=AliasChoices("fechaNacimiento", "fecha_nacimiento"),
        description="ISO YYYY-MM-DD o DD/MM/YYYY",
    )

    @field_validator("fechaNacimiento")
    @classmethod
    def validate_fecha_nacimiento(cls, value: str) -> str:
        return _normalize_fecha_nacimiento(value)


class ClienteOut(ClienteIn):
    clienteId: str


def _cliente_item_for_response(item: dict[str, Any]) -> dict[str, Any]:
    data = dict(item)
    raw = data.pop("fecha_nacimiento", None)
    if raw is not None and "fechaNacimiento" not in data:
        data["fechaNacimiento"] = _normalize_fecha_nacimiento(str(raw))
    elif "fechaNacimiento" in data:
        data["fechaNacimiento"] = _normalize_fecha_nacimiento(str(data["fechaNacimiento"]))
    return data


def _decimal_to_float(obj: Any) -> Any:
    if isinstance(obj, list):
        return [_decimal_to_float(i) for i in obj]
    if isinstance(obj, dict):
        return {k: _decimal_to_float(v) for k, v in obj.items()}
    if isinstance(obj, Decimal):
        return float(obj) if obj % 1 else int(obj)
    return obj


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/productos")
def list_productos():
    resp = productos_table.scan()
    items = [ProductoOut(**_producto_item_for_response(i)).model_dump() for i in resp.get("Items", [])]
    return {"items": items}


@app.post("/productos", response_model=ProductoOut, status_code=201)
def create_producto(body: ProductoIn):
    pid = str(uuid.uuid4())
    item = {
        "productoId": pid,
        "nombre": body.nombre,
        "precio": Decimal(str(body.precio)),
        "stock": body.stock,
    }
    productos_table.put_item(Item=item)
    return ProductoOut(productoId=pid, **body.model_dump())


@app.get("/productos/{producto_id}", response_model=ProductoOut)
def get_producto(producto_id: str):
    resp = productos_table.get_item(Key={"productoId": producto_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    return ProductoOut(**_producto_item_for_response(item))


@app.put("/productos/{producto_id}", response_model=ProductoOut)
def update_producto(producto_id: str, body: ProductoIn):
    resp = productos_table.get_item(Key={"productoId": producto_id})
    if not resp.get("Item"):
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    item = {
        "productoId": producto_id,
        "nombre": body.nombre,
        "precio": Decimal(str(body.precio)),
        "stock": body.stock,
    }
    productos_table.put_item(Item=item)
    return ProductoOut(productoId=producto_id, **body.model_dump())


@app.delete("/productos/{producto_id}", status_code=204)
def delete_producto(producto_id: str):
    resp = productos_table.get_item(Key={"productoId": producto_id})
    if not resp.get("Item"):
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    productos_table.delete_item(Key={"productoId": producto_id})


@app.get("/clientes")
def list_clientes():
    resp = clientes_table.scan()
    items = [ClienteOut(**_cliente_item_for_response(i)).model_dump() for i in resp.get("Items", [])]
    return {"items": items}


@app.post("/clientes", response_model=ClienteOut, status_code=201)
def create_cliente(body: ClienteIn):
    cid = str(uuid.uuid4())
    item = {"clienteId": cid, **body.model_dump()}
    clientes_table.put_item(Item=item)
    return ClienteOut(clienteId=cid, **body.model_dump())


@app.get("/clientes/{cliente_id}", response_model=ClienteOut)
def get_cliente(cliente_id: str):
    resp = clientes_table.get_item(Key={"clienteId": cliente_id})
    item = resp.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    return ClienteOut(**_cliente_item_for_response(item))


@app.put("/clientes/{cliente_id}", response_model=ClienteOut)
def update_cliente(cliente_id: str, body: ClienteIn):
    resp = clientes_table.get_item(Key={"clienteId": cliente_id})
    if not resp.get("Item"):
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    item = {"clienteId": cliente_id, **body.model_dump()}
    clientes_table.put_item(Item=item)
    return ClienteOut(clienteId=cliente_id, **body.model_dump())


@app.delete("/clientes/{cliente_id}", status_code=204)
def delete_cliente(cliente_id: str):
    resp = clientes_table.get_item(Key={"clienteId": cliente_id})
    if not resp.get("Item"):
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    clientes_table.delete_item(Key={"clienteId": cliente_id})
