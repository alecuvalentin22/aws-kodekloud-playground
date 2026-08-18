# Drill 08 — Kong

Kong is installed DB-less, config driven by Kubernetes CRDs.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n kong get pods
kubectl apply -f kubernetes/kong/
curl -i http://NODE_IP:30080/demo
```

## The mapping from APISIX (Valentin's angle)
| Concept | APISIX | Kong |
|---|---|---|
| Match a request | Route | Route / Ingress |
| Backend pool | Upstream | Service + Targets |
| Caller identity | Consumer | KongConsumer |
| Behaviour hook | Plugin | KongPlugin |
| Config store | etcd | PostgreSQL or DB-less YAML |
| Rate limit plugin | `limit-count` | `rate-limiting` |
| OIDC plugin | `openid-connect` | `oidc` / `openid-connect` |

## Your strongest angle
You operate an OIDC identity provider. Put the OIDC plugin in front of a service
and explain what the gateway validates: signature against the IdP's JWKS, `iss`,
`aud`, `exp`, and how token introspection differs from local JWT validation.
Almost no candidate for an operations role can explain that from experience.
Lead with it — not with gateway trivia.

## DB-less vs PostgreSQL
DB-less means config is declarative and immutable at runtime — no admin API
writes, config ships with the deployment. That is the GitOps-friendly mode, and
it is a good answer to "how do you manage gateway config?". The PostgreSQL mode
exists for the Admin API and for plugins that need runtime state. Knowing why
you would pick each connects straight to the relational-database line in the JD.
