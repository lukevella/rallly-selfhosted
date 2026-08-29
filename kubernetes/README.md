# Rallly Kubernetes Manifests

> **Looking to deploy on Kubernetes?** Consider the [Helm chart](../charts/rallly) instead. It covers everything below plus object storage (bundled Garage or external S3), SMTP authentication, OIDC single sign-on, housekeeping CronJobs.

This directory contains base Kubernetes manifests to self-host Rallly. It separates configuration (ConfigMaps) from sensitive data (Secrets) and uses a StatefulSet for the PostgreSQL database.

## Prerequisites

- A Kubernetes cluster.
- `kubectl` configured to talk to your cluster.
- An Ingress Controller (e.g., NGINX) installed.

## Configuration

1. **Secrets (`secrets.yaml`):**
   - **Important:** Do not commit the `secrets.yaml` file with real credentials to version control. Consider adding `secrets.yaml` to your `.gitignore` file to prevent accidental commits.
   - Update `POSTGRES_PASSWORD` and `SECRET_PASSWORD` (use `openssl rand -hex 32` to generate).
   - **Critical:** Ensure the password in `DATABASE_URL` matches `POSTGRES_PASSWORD`. Both must use the same value.
   - **Format:** The `DATABASE_URL` format should look like this: `postgres://<user>:<password>@<postgres-service-name>:5432/<db-name>`.

2. **Config (`rallly-config.yaml`):**
   - Update `NEXT_PUBLIC_BASE_URL` to match your domain.
   - Configure your SMTP settings for emails.

3. **Ingress (`ingress.yaml`):**
   - Change `host: rallly.example.com` to your actual domain.
   - Ensure `ingressClassName` matches your cluster's controller (default is set to `nginx`).
   - **TLS:**
     - **Option 1 (Manual):** Create a TLS Secret: `kubectl create secret tls rallly-tls --cert=path/to/cert --key=path/to/key`
     - **Option 2 (cert-manager):** See comments in `ingress.yaml` for automatic certificate provisioning setup.

## Deployment Order

Apply the manifests in the following order to ensure dependencies are met:

```bash
# 1. Apply Secrets and Config first
kubectl apply -f secrets.yaml
kubectl apply -f rallly-config.yaml

# 2. Apply Database (StatefulSet)
kubectl apply -f postgres.yaml

# Wait for database to be ready
kubectl wait --for=condition=ready pod -l app=postgres --timeout=300s

# 3. Apply Application (Deployment)
kubectl apply -f rallly.yaml

# 4. Apply Ingress
kubectl apply -f ingress.yaml
```

**Note:** If you update `secrets.yaml` or `rallly-config.yaml` _after_ deployment, you must restart the Rallly pods for changes to take effect:

```bash
kubectl rollout restart deployment rallly
```

This performs a **rolling restart**, so there will be no downtime. However, ensure the new configuration is valid; if pods fail to start, check the logs with `kubectl logs -f deployment/rallly`.

**Note:** This assumes your Deployment has multiple replicas. If running a single Rallly instance (1 replica), there will be brief downtime during the restart.

## Verification

Check that the pods are running:

```bash
kubectl get pods
```

The Postgres pod should show `1/1 Running` and the Rallly pod should eventually show `1/1 Running` once the liveness probe passes.

## Notes on Storage

The PostgreSQL StatefulSet requests a 1Gi PersistentVolume. Ensure your cluster has a default StorageClass configured, or update the `volumeClaimTemplates` in `postgres.yaml` to specify a StorageClass. If no StorageClass is available, the PersistentVolumeClaim will remain pending and the postgres pod will not start. Check your cluster's available StorageClasses with `kubectl get storageclass`.

**Quick check:** Run `kubectl get storageclass` before deployment. If the output is empty, ask your cluster administrator to configure a default StorageClass, or update `postgres.yaml` to reference an existing one.

## Notes on Backups

For production deployments, implement regular PostgreSQL backups. Consider using:

- Kubernetes-native backup tools (e.g., Velero)
- Scheduled pg_dump jobs within the cluster
- Cloud-provider managed backups (if using managed K8s)

Refer to your cluster provider's backup documentation for recommendations.
