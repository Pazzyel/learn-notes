# Kubernetes 概念

Kubernetes 为你提供了一个更加现代化的，能够弹性运行分布式系统的框架。它负责你的应用的扩展和故障切换，提供部署模式等

它提供以下能力

- 服务发现与负载均衡（注册中心）
- 配置管理（配置中心）
- 存储编排
- 自动化的服务发布与回滚

它相比传统的微服务框架（如Java 的 Spring Cloud），不提供服务之间的RPC调用，设计者认为这种应用级服务应该由用户自己进行选型。K8s只需要做好服务的编排和管理

## 使用minikube在本地上尝试运行Kubernetes集群

创建集群

```bash
minikube start
```

- `--name`参数用于指定集群的名称

查看集群状态

```bash
minikube status
```

启动 Web UI

```bash
minikube dashboard
```

查看启动的service

```bash
minikube service hello-node
```

## 和你的集群进行互动

Kubernetes 基本命令结构是

```bash
kubectl action resource
```

除了命令之外，你也可以在dashboard上管理

### Pod和Deployment

Kubernetes Pod 是由一个或多个为了管理和联网而绑定在一起的容器构成的组。 Pod 可以有一个或者多个 Docker container

一个 Pod 总是运行在某个 Node（节点） 上。节点是 Kubernetes 中工作机器， 可以是虚拟机或物理计算机

> **只有容器紧耦合并且需要共享磁盘等资源时，才应将其编排在一个 Pod 中**

命令列表

- `kubectl get` - 列出资源
- `kubectl describe` - 显示有关资源的详细信息
- `kubectl logs` - 打印 Pod 中容器的日志
- `kubectl exec` - 在 Pod 中的容器上执行命令

Kubernetes Deployment 是一个Pod的监测+管理器，可以检查 Pod 的健康状况，并在 Pod 中的容器终止的情况下重新启动新的容器。通过创建deployment的方法来创建Pod

创建管理 Pod 的 Deployment

```bash
kubectl create deployment hello-node --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- /agnhost netexec --http-port=8080
```

- `--image`指定了运行的容器镜像

查看 Deployment：

```bash
kubectl get deployments
```

查看 Pod：

```bash
kubectl get pods
```

进入容器内部，这在在 Pod 的容器中启动一个 bash 会话

```bash
kubectl exec -it "$POD_NAME" -- bash
```

查看集群事件：

```bash
kubectl get events
```

查看 kubectl 配置：

```bash
kubectl config view
```

查看 Pod 中容器的应用程序日志

```bash
kubectl logs xxxxxx
```

需要把`xxxxxx`替换成`kubectl get pods`获得的名称

### Service

Service 就是 K8s 的注册中心

默认情况下，Pod 只能通过 Kubernetes 集群中的内部隔离 IP 地址访问

通过 Kubernetes Service，使得 hello-node Pod 容器可以从 Kubernetes 虚拟网络的外部访问

使用 kubectl expose 命令将 Pod 端口暴露给公网

```bash
kubectl expose deployment hello-node --type=LoadBalancer --port=8080
```

- `--type=LoadBalancer`，表明你希望将你的 Service 暴露到集群外部，内部是负载均衡的，平台将提供一个外部 IP 访问
- `--port=8080`，暴露的端口

查看你创建的 Service：

```bash
kubectl get services
```

删除资源采用`kubectl delete`

```bash
kubectl delete service hello-node
kubectl delete deployment hello-node
```

### Proxy

创建一个代理，将通信转发到集群范围的私有网络

```bash
kubectl proxy
```

这样，你同样也可以访问到集群内部隔离网络

它的本质是为当前的计算机建立一个代理，代理负责把请求转发给集群内部

这是一个客户端命令，而不是集群管理命令，它对集群是没有任何直间改变的（而`kubectl expose`暴露出来的service是一种对集群的修改）

### 服务的多个实例

服务数量上的扩缩是通过改变 Deployment 中的副本数量来实现的

```bash
kubectl scale deployments/$YOUR_DEPLOYMENT_NAME --replicas=4
```

- `--replicas`指定副本数量

这将使得一个Deployment被扩充到4个副本，多个副本间的负载均衡是自动的

### 滚动更新

滚动更新是指，在一个Deployment下有多个实例，当服务要被更新到版本时，Kubernetes会慢慢的替换其中几个Pod，直到所有Pod都被替换。更新过程中不存在没有任何Pod不可用的情况

当一个Pod正在执行更新操作，我们认为它是不可用的。还没有更新/更新完成的Pod是可用的

默认情况下，更新期间不可用的 Pod 的个数上限和可以创建的新 Pod 个数上限都是 1

使用下列命令让 Kubernetes 对某个 Deployment 执行滚动更新

```bash
kubectl set image deployments/kubernetes-bootcamp kubernetes-bootcamp=docker.io/jocatalin/kubernetes-bootcamp:v2
```

如果发现新发布的版本有问题，可以回滚到上一个版本

```bash
kubectl rollout undo deployments/kubernetes-bootcamp
```

通过`kubectl describe pods`查看 Pod 的版本

### 其它

未完待续...
