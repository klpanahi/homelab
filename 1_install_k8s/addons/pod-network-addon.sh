##Install flannel for networking
kubectl apply -f ./kube-flannel.yml
## note, I had to download the kube-flannel.yml from github and replace the default cidr with the one I configured when I create the cluster
#Default: 10.244.0.1/16
#Mine: 10.0.0.1/16