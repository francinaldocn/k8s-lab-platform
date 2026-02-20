# Gateway API: Guia de Arquitetura e Implementação

Este guia descreve como a **Gateway API** é utilizada no `k8s-lab-platform`,
fornecendo uma base de rede moderna, orientada por responsabilidades e
escalável, além do modelo tradicional baseado em Ingress.

---

## 1. Contexto Técnico

A Gateway API representa a evolução da rede no Kubernetes.  
Neste laboratório utilizamos o **NGINX Gateway Fabric (NGF)** como mecanismo
de implementação.

### Por que Gateway API?

- **Orientada a responsabilidades**: separação clara entre infraestrutura
  (GatewayClass/Gateway) e roteamento de aplicações (HTTPRoute).
- **Extensível**: suporte nativo a manipulação de headers, roteamento por peso
  e gerenciamento avançado de tráfego.
- **Preparada para o futuro**: padronizada entre distribuições Kubernetes e
  provedores de nuvem.

---

## 2. Visão Geral da Infraestrutura

A plataforma já configura um ponto de entrada para o cluster:

- **Gateway**: `default-gateway` (namespace: `nginx-gateway`)
- **GatewayClass**: `nginx`
- **Portas expostas**: 80 (HTTP) e 443 (HTTPS), mapeadas do Kind para a máquina local.

---

## 3. Padrões de Implantação

### Padrão A — Exposição HTTP (Tráfego Norte-Sul)

Exemplo para expor um serviço simples:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: dynamic-api-route
  namespace: my-data-team
spec:
  parentRefs:
  - name: default-gateway
    namespace: nginx-gateway
  hostnames:
  - "api.cluster.test"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: my-api-service
      port: 8080
```

### Padrão B: HTTPS Seguro com cert-manager

O laboratório inclui um **Local CA Issuer**. O NGF exige que a secret TLS esteja no mesmo namespace do Gateway.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: platform-tls
  namespace: nginx-gateway
spec:
  secretName: platform-tls-secret
  issuerRef:
    name: local-ca-issuer
    kind: ClusterIssuer
  commonName: dashboard.cluster.test
  dnsNames:
  - dashboard.cluster.test
```

---

## 4. Caso Real: Stack de Monitoramento

O Grafana é exposto automaticamente utilizando o seguinte modelo:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: cattle-monitoring-system
spec:
  parentRefs:
  - name: default-gateway
    namespace: nginx-gateway
  hostnames:
  - "grafana.cluster.test"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: rancher-monitoring-grafana
      port: 80
```

> [!TIP]
> Adicione os domínios personalizados ao /etc/hosts:
> `127.0.0.1 rancher.cluster.test grafana.cluster.test api.cluster.test`

---

## 5. Gerenciamento via Rancher (v2.13.x)

O Rancher oferece suporte visual à Gateway API:
1. Acesse **More Resources** → **Gateway.Networking**.
2. Caso **HTTPRoutes** não apareça, utilize a busca e digite **HTTPRoute**.
3. As rotas são vinculadas a namespaces — selecione **All Namespaces** se necessário.
4. Utilize a visualização em grafo para acompanhar **Gateway** → **HTTPRoute** → **Service**.


## 6. Troubleshooting NGF

Se o tráfego não alcançar o serviço:

```bash
kubectl describe httproute <nome-da-rota> -n <namespace>
```

Verifique as condições:

- Accepted
- Programmed

Se **Programmed=false**, confirme se o **parentRefs** aponta corretamente
para **default-gateway** no namespace **nginx-gateway**.

---
*Blueprint Arquitetural - Modern Data Infra Lab*
