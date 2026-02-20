# Gateway API: Architecture and Implementation Guide

This guide explains how **Gateway API** is implemented in the `k8s-lab-platform`,
providing a modern, role-oriented, and scalable networking foundation beyond
traditional Ingress controllers.

---

## 1. Technical Context

Gateway API represents the evolution of Kubernetes networking.  
This lab uses **NGINX Gateway Fabric (NGF)** as the implementation engine.

### Why Gateway API?

- **Role-oriented**: clear separation between infrastructure ownership
  (GatewayClass/Gateway) and application routing (HTTPRoute).
- **Extensible**: native support for header manipulation, weighted routing,
  and advanced traffic management.
- **Future-ready**: standardized across major Kubernetes distributions and
  cloud providers.

---

## 2. Infrastructure Overview

The platform preconfigures a cluster entry point:

- **Gateway**: `default-gateway` (namespace: `nginx-gateway`)
- **GatewayClass**: `nginx`
- **Exposed ports**: 80 (HTTP) and 443 (HTTPS), mapped from Kind to the host.

---

## 3. Deployment Patterns

### Pattern A — Standard HTTP Exposure (North-South Traffic)

Example exposing a simple service:

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

### Pattern B: Secure HTTPS with cert-manager

The lab includes a **Local CA Issuer**. NGF requires the TLS secret to exist in the same namespace as the Gateway.

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

## 4. Real-World Case: Monitoring Stack

Grafana is automatically exposed using the following routing model:

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
> **Add custom domains to /etc/hosts:**
> `127.0.0.1  rancher.cluster.test grafana.cluster.test api.cluster.test`

---

## 5. Management via Rancher UI (v2.13.2)

Rancher provides native Gateway API visualization:

1. Go to **More Resources** -> **Gateway.Networking**.
2. If `HTTPRoutes` is missing, use the search icon and type `HTTPRoute`.
3. Routes are namespace-scoped — select **All Namespaces** if needed.
4. Use the graph view to visualize **Gateway → HTTPRoute → Service**.

---

## 6. Troubleshooting NGF

If traffic does not reach the service:

```bash
kubectl describe httproute <route-name> -n <namespace>
```

Check the conditions:

- **Accepted**
- **Programmed**

If **Programmed=false**, verify that **parentRefs** correctly targets
**default-gateway** in the **nginx-gateway** namespace.

---
*Architectural Blueprint - Modern Data Infra Lab*
