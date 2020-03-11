# Generic Ingress

The idea is to get a similar experience with Kubernetes ingress as you get with [PWS](https://run.pivotal.io/) - you don't have to futz with DNS or certificates and every app you deploy is addressable immediately on the internet. In PWS the apps get a route in `*.cfapps.io`. Pivotal owns the `cfapps.io` domain and they have created wildcard DNS records and SSL certificates. Pivotal only had to do that once.

To get a similar experience with Kubernetes running *anywhere* doesn't sound like such a crazy idea. This project is what I did to prove that it works. In PWS every app gets its own subdomain. The idea here is that every Kubernetes cluster gets its own subdomain (e.g. `mycluster.cfapps.io`), and apps are registered as sub-subdomains below that (e.g. `demo.mycluster.cfapps.io`). The cluster can be running anywhere (including locally).

## User Experience

> NOTE: These instructions expose an app on `demo.food.test.dsyer.com`. It will only work if the tunnel server is running on `test.dsyer.com` and no-one else is using the `food` subdomain.

Get yourself a Kubernetes cluster. It can be anywhere, even running locally using `kind` (for instance) or `kubeadm`. Significantly, it doesn't have to support the `LoadBalancer` type of service - the default `ClusterIP` type is fine.

### Nginx Set Up

Add the standard off-the-shelf [nginx ingress](https://github.com/kubernetes/ingress-nginx) but instead of using `NodePort` or `LoadBalancer` for the nginx service, switch to the default `ClusterIP`:

```
$ kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.30.0/deploy/static/mandatory.yaml
$ kubectl apply -f <(curl https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.30.0/deploy/static/provider/baremetal/service-nodeport.yaml | sed -i -e '/  type:.*/d')
```

The nginx ingress lives in its own namespace. You only have to do this step once per cluster. To check that it is working look for the `ingress-nginx` service and make sure it is of type `ClusterIP`:

```
$ kubectl get all --namespace=ingress-nginx
NAME                                            READY   STATUS    RESTARTS   AGE
pod/nginx-ingress-controller-7fcf8df75d-nt92c   1/1     Running   0          5d21h

NAME                    TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)          AGE
service/ingress-nginx   ClusterIP   10.103.4.16   <none>        80/TCP,443/TCP   5d21h
...
```

### Add the Tunnel

Add another process (`Pod`) to the `ingress-nginx` namespace. Change the value of `DOMAIN` to your own unique value (with more than 3 characters):

```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-tunnel
  namespace: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: app
        image: efrecon/localtunnel
        env:
        - name: DOMAIN
          value: food
        args:
        - --host
        - http://$(DOMAIN).test.dsyer.com
        - --local-host
        - ingress-nginx.ingress-nginx.svc.cluster.local
        - --port
        - "80"
```

If you are using your own domain registration (see below) then change the `test.dsyer.com` bit as well.

### Application Deployment

Deploy an application with a standard `Deployment` and `Service`. E.g.

```
$ kubectl create deployment demo --image=dsyer/demo
$ kubectl create service clusterip demo --tcp=80:8080
```

Then expose it via the nginx ingress in the normal way, using a hostname rule in the subdomain that the tunnel requested in the last step:

```
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  name: ingress
  annotations:
    kubernetes.io/ingress.class: "nginx"
spec:
  rules:
  - host: demo.food.test.dsyer.com
    http:
      paths:
        - path: /
          backend:
            serviceName: app
            servicePort: 80
```

Test it:

```
$ curl demo.food.test.dsyer.com
Hello World!!!
$ curl demo.food.test.dsyer.com/actuator
{"_links":{"self":...}}
```

As soon as the ingress is active in the cluster the app is visible on the internet. No frustrating 10 minutes delay while the DNS propagation works itself out (sometimes it takes over an hour for me with a new app on GKE without the tunnel). Amazing!

## Build and Run The Server

The server that listens on the base domain isn't very complicated, and could definitely be improved. It exposes TCP connections on random ports (one per client, or equivalently per subdomain), so it isn't easy to run in Kubernetes, but you can run it with `docker` using the host network.

Grab the server code from github:

```
$ mkdir -p server
$ curl -L https://github.com/dsyer/localtunnel-server/archive/master.tar.gz | \
    tar xz -C server --strip-components 1
```

### External DNS Set Up

The `site.conf` and `docker-compose.yaml` both carry references to the `test.dsyer.com` subdomain. To run the server yourself you will need  your own subdomain, registered in an external DNS provider and with a wildcard A record for all sub-subdomains. Make the A record and check that it is working, e.g:

```
$ dig foo.test.dsyer.com

; <<>> DiG 9.11.3-1ubuntu1.11-Ubuntu <<>> foo.test.dsyer.com
...
;; ANSWER SECTION:
foo.test.dsyer.com.	10	IN	A	35.242.130.130
...
```

### SSL Set Up

SSL isn't working completely yet, but you still need certs (unless you want to hack that section out of the nginx proxy). So, get a wildcard cert for your subdomain, and make an `ssl` directory with the certificate and private key in PEM format:

```
$ ls ssl
server.crt  server.key
```

### Run the Server

```
$ docker-compose up
...
Creating localtunnel_localtunnel_1 ... done
Creating localtunnel_nginx_1       ... done
Attaching to localtunnel_localtunnel_1, localtunnel_nginx_1
```

If any clients connect you will see it in the logs

```
localtunnel_1  | 2020-03-11T09:07:10.844Z localtunnel:server Retrieving clientId: test.dsyer.com
localtunnel_1  | 2020-03-11T09:07:10.849Z localtunnel:server Parts: % [ 'food' ]
localtunnel_1  | 2020-03-11T09:07:10.849Z localtunnel:server making new client with id food
localtunnel_1  | 2020-03-11T09:07:10.852Z lt:TunnelAgent[food] tcp server listening on port: 33145
```

and when HTTP requests come in they are forwarded through the tunnel to the remote Kubernetes ingress. For example:

```
nginx_1        | 86.30.187.113 - - [11/Mar/2020:09:42:53 +0000] "GET /actuator HTTP/1.1" demo.food.test.dsyer.com /actuator 200 469 "-" "curl/7.58.0" "-"
```

### Sanity Check

You request a tunnel by sending a simple HTTP GET to a sub-subdomain:

```
$ curl spam.test.dsyer.com
{"id":"spam","port":38377,"max_conn_count":10,"url":"http://spam.test.dsyer.com"}
```

If you get that response then it is working and you should see nginx logging the request, as well as some debug logging from the localtunnel server.