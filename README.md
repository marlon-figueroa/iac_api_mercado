# IaC API REST Supermercado

Infraestructura como código (CloudFormation) para una API REST de supermercado: **API Gateway** → **VPC Link** → **NLB interno (Istio)** → **FastAPI en EKS** → **DynamoDB**.

## Arquitectura

```
Cliente → API Gateway (/productos, /clientes) → VPC Link → NLB interno → Istio → FastAPI → DynamoDB
                                                                 ↑
                                                          Karpenter (Spot)
```

## Documentación

- Documento técnico completo: [docs/PROYECTO.md](docs/PROYECTO.md)
- PDF (local): `make docs-pdf` → `docs/PROYECTO.pdf` (requiere `pandoc`, `mermaid-cli`, LaTeX)

## Prerrequisitos

- AWS CLI v2 configurado (`aws sts get-caller-identity`)
- `kubectl`, `helm` (3.x)
- Python 3 (para `scripts/load-vars.sh`; no requiere PyYAML)
- Opcional: `cfn-lint` para validación
- Cuenta AWS con cuota para EKS, NAT Gateway y API Gateway

## Configuración

Edita [`vars.yaml`](vars.yaml): región, entorno, nombre del cluster, tablas DynamoDB y tipos de instancia.

## Despliegue rápido

```bash
make infra          # CloudFormation (vpc → kms → dynamodb → iam → eks → ec2)
make kubeconfig     # kubectl contra el cluster
make platform       # Karpenter + Istio + gateway NLB interno
make app            # FastAPI (build local o imagen)
make discover-nlb   # escribe NlbArn / NlbDnsName en vars.yaml
make api            # API Gateway con VPC Link
make smoke          # prueba HTTP básica
```

O todo en secuencia:

```bash
make all
```

## Stacks CloudFormation

| Stack | Carpeta | Descripción |
|-------|---------|-------------|
| `{Project}-{Env}-vpc` | `vpc/` | VPC, subnets, NAT, tags Karpenter/EKS |
| `{Project}-{Env}-kms` | `kms/` | CMK secrets EKS |
| `{Project}-{Env}-dynamodb` | `dynamodb/` | Tablas productos y clientes |
| `{Project}-{Env}-iam` | `iam/` | Roles cluster/nodos/Karpenter node, policies |
| `{Project}-{Env}-eks` | `eks/` | Cluster, bootstrap MNG spot, OIDC, IRSA |
| `{Project}-{Env}-ec2` | `ec2/` | SG NLB, parámetros SSM |
| `{Project}-{Env}-api` | `api_gateway/` | REST API + VPC Link (requiere NLB) |

Stack maestro opcional: [`template.yaml`](template.yaml) + `aws cloudformation package` hacia S3.

## DynamoDB

- **productos**: `productoId` (PK), `nombre`, `precio`, `stock`
- **clientes**: `clienteId` (PK), `nombre`, `fechaNacimiento` (ISO `YYYY-MM-DD`)

## Costos (dev)

- NAT Gateway: costo fijo principal
- EKS control plane + 1 nodo bootstrap spot + nodos Karpenter spot
- DynamoDB on-demand

## Versiones fijadas (vars.yaml)

- Kubernetes: ver `KubernetesVersion` (1.33+ requiere nodos **AL2023**; AL2 no aplica)
- Karpenter chart: `KarpenterChartVersion`
- Istio: `IstioVersion`
