helm repo add runix https://helm.runix.net

kubectl create namespape pgadmin
helm install pgadmin4 runix/pgadmin4 --namespace pgadmin