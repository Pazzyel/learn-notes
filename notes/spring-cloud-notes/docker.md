# docker

- 镜像：英文是image
- 容器：英文是container

镜像是要运行的应用程序及其环境，容器是独立运行的隔离环境。运行docker run，Docker会根据命令中的镜像名称自动搜索并下载镜像

docker镜像的官方仓库是<https://hub.docker.com/>，可以使用其它第三方仓库，也可以搭建私有仓库

配置docker开机自启

    # Docker开机自启
    systemctl enable docker

    # Docker容器开机自启
    docker update --restart=always [容器名/容器id]

如果是wsl里运行的Linux，可以通过`ip route | grep default`查看wsl虚拟器对应宿主机ip

查看端口占用`sudo netstat -tulnp`

## 命令解读

    docker run -d \
    --name mysql \
    -p 3306:3306 \
    -e TZ=Asia/Shanghai \
    -e MYSQL_ROOT_PASSWORD=123 \
    mysql

这是一个使用docker部署mysql服务的命令

- docker run -d ：创建并运行一个容器，-d则是让容器以后台进程运行
- --name mysql  : 给容器起个名字叫mysql，注意这个名称是自定义的容器名称，不是镜像的名称
- -p 3306:3306 : 设置端口映射，-p 宿主机端口:容器内端口
- -e TZ=Asia/Shanghai : 配置容器内进程运行时的环境变量，TZ是设置时区，MYSQL_ROOT_PASSWORD是设置MySQL的root用户密码。其它可以查看镜像的文档说明（在docker hub搜索）
- mysql : 设置**镜像名称**，Docker会根据这个名字搜索并下载镜像
  - 格式：REPOSITORY:TAG，例如mysql:8.0，其中REPOSITORY可以理解为镜像名，TAG是版本号
  - 在未指定TAG的情况下，默认是最新版本，也就是mysql:latest

## 常见命令

官方文档<https://docs.docker.com/reference/cli/docker/>

| 命令         | 作用                             | 官方文档超链接地址 |
|--------------|----------------------------------|--------------------|
| docker pull  | 从远程仓库拉取镜像               | [pull](https://docs.docker.com/reference/cli/docker/image/pull/) |
| docker push  | 将本地镜像推送到远程仓库         | [push](https://docs.docker.com/reference/cli/docker/image/push/) |
| docker images| 列出本地已有镜像                 | [images](https://docs.docker.com/reference/cli/docker/image/ls/) |
| docker rmi   | 删除本地镜像                     | [rmi](https://docs.docker.com/reference/cli/docker/image/rm/) |
| docker run   | 基于镜像创建并启动容器（不能重复创建）| [run](https://docs.docker.com/reference/cli/docker/container/run/) |
| docker stop  | 停止一个或多个运行中的容器       | [stop](https://docs.docker.com/reference/cli/docker/container/stop/) |
| docker start | 启动已停止的容器                 | [start](https://docs.docker.com/reference/cli/docker/container/start/) |
| docker restart| 重启容器                        | [restart](https://docs.docker.com/reference/cli/docker/container/restart/) |
| docker rm    | 删除一个或多个容器               | [rm](https://docs.docker.com/reference/cli/docker/container/rm/) |
| docker ps    | 列出运行中的容器                 | [ps](https://docs.docker.com/reference/cli/docker/container/ls/) |
| docker logs  | 查看容器日志                     | [logs](https://docs.docker.com/reference/cli/docker/container/logs/) |
| docker exec  | 在运行中的容器内执行命令         | [exec](https://docs.docker.com/reference/cli/docker/container/exec/) |
| docker save  | 将镜像保存为本地压缩文件           | [save](https://docs.docker.com/reference/cli/docker/image/save/) |
| docker load  | 从本地压缩文件加载镜像               | [load](https://docs.docker.com/reference/cli/docker/image/load/) |
| docker inspect| 显示容器或镜像的详细信息        | [inspect](https://docs.docker.com/reference/cli/docker/inspect/) |

拉取镜像只是把镜像拉取到本地仓库，启动容器优先检查本地仓库

如果需要在进入运行的容器进行命令行交互，需要-it

- -i (--interactive)：保持容器的 标准输入 (STDIN) 打开，即使没有连接也不会关闭。
- -t (--tty)：分配一个伪终端 (pseudo-TTY)，让你在容器里能有交互式的终端环境

如果需要给常用docker命令起别名，应该修改bash shell的启动文件`/root/.bashrc`，并执行`source /root/.bashrc`

    alias rm='rm -i'
    alias cp='cp -i'
    alias mv='mv -i'
    alias dps='docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}\t{{.Names}}"'
    alias dis='docker images'

    # Source global definitions
    if [ -f /etc/bashrc ]; then
            . /etc/bashrc
    fi

## 数据卷

容器提供隔离环境，但程序运行产生的数据、程序运行依赖的配置都应该与容器解耦

数据卷（volume）是一个虚拟目录，是容器内目录与宿主机目录之间映射。通过建立映射，把容器内某个目录挂载到物理机目录下

默认情况下，/var/lib/docker/volumes这个目录就是默认的存放所有容器数据卷的目录，其下再根据数据卷名称创建新目录，格式为/数据卷名/_data

| 命令                  | 作用                     | 官方文档超链接地址 |
|-----------------------|--------------------------|--------------------|
| docker volume create  | 创建一个新的数据卷       | [create](https://docs.docker.com/reference/cli/docker/volume/create/) |
| docker volume ls      | 列出所有数据卷           | [ls](https://docs.docker.com/reference/cli/docker/volume/ls/) |
| docker volume rm      | 删除一个或多个数据卷     | [rm](https://docs.docker.com/reference/cli/docker/volume/rm/) |
| docker volume inspect | 查看数据卷的详细信息     | [inspect](https://docs.docker.com/reference/cli/docker/volume/inspect/) |
| docker volume prune   | 删除所有未使用的数据卷   | [prune](https://docs.docker.com/reference/cli/docker/volume/prune/) |

容器与数据卷的挂载要在创建容器时配置，对于创建好的容器，是不能设置数据卷的。而且创建容器的过程中，数据卷会自动创建

配置的方式是在docker run时指定-v参数，例如

    -v html:/usr/share/nginx/html

把容器的/usr/share/nginx/html创建为数据卷，名字是html，这个目录默认挂载到宿主机的/var/lib/docker/volumes/html/_data

通过`docker volume inspect xxx`查看数据卷详情

docker和宿主机进行文件上的共享不一定需要通过volume，也可以靠cp命令把宿主机的文件复制到容器内部的目录

    docker cp /path/to/file.sql <mysql_container>:/tmp/file.sql

把宿主机的/path/to/file.sql复制到容器内的/tmp/file.sql

### 匿名卷

    "Mounts": [
        {
            "Type": "volume",
            "Name": "1bef3fe38b7575d02773ea66532a95abfc8215c0f3853e81caef77ba5233dbfb",
            "Source": "/var/lib/docker/volumes/1bef3fe38b7575d02773ea66532a95abfc8215c0f3853e81caef77ba5233dbfb/_data",
            "Destination": "/data",
            "Driver": "local",
            "Mode": "",
            "RW": true,
            "Propagation": ""
        }
    ]

    "Config": {
        // ... 略
        "Volumes": {
            "/data": {}
        },
    }

如上述配置，容器的Volumes声明了一个本地目录，需要挂载数据卷，但是数据卷未定义，Mounts中有几个属性

- Name：数据卷名称。由于定义容器未设置容器名，这里的就是匿名卷自动生成的名字，一串hash值。
- Source：宿主机目录
- Destination : 容器内的目录

把容器内的/data挂载到/var/lib/docker/volumes/1bef3fe38b7575d02773ea66532a95abfc8215c0f3853e81caef77ba5233dbfb/_data，这也是一个数据卷，只不过没有指定名字，是匿名卷

匿名数据卷对应的目录，其使用方式与普通数据卷没有差别

### 直接挂载本地目录

一般情况下，使用-v会挂载到/var/lib/docker/volumes的对应位置

    -v 数据卷名称:容器内目录

也可以手动指定挂载的宿主机目录/文件，这种写法本地目录或文件必须以 / 或 ./开头，如果直接以名字开头，会被识别为数据卷名而非本地目录名

    # 挂载本地目录
    -v 本地目录:容器内目录
    # 挂载本地文件
    -v 本地文件:容器内文件

## 打包为镜像

一个Java项目，需要的环境包括

- Linux运行环境（java项目并不需要完整的操作系统，仅仅是基础运行环境即可）
- JDK
- 项目jar包
- 配置启动脚本

镜像按照操作的步骤分层叠加而成，每一层形成的文件都会单独打包并标记一个唯一id，称为Layer（层）。自底向上，层越低越通用。例如操作系统层，Docker官方提供的Ubuntu等镜像可以作为基础镜像，无需自行打包

打包镜像，有记录镜像结构的文件dockerfile，参考官方文档<https://docs.docker.com/engine/reference/builder/>，常用语法有

|指令|说明|示例|
|---|-----|----|
|FROM|指定基础镜像|FROM ubuntu|
|ENV|设置环境变量，可在后面指令使用|ENV key value|
|COPY|拷贝本地文件到镜像的指定目录|COPY ./xx.jar /tmp/app.jar|
|RUN|执行Linux的shell命令，一般是安装过程的命令|RUN apt install gcc|
|EXPOSE|指定容器运行时监听的端口，是给镜像使用者看的|EXPOSE 8080|
|ENTRYPOINT|镜像中应用的启动命令，容器运行时调用|ENTRYPOINT java -jar xx.jar|

案例：基于Ubuntu构建Java应用

    # 指定基础镜像
    FROM ubuntu:16.04
    # 配置环境变量，JDK的安装目录、容器内时区
    ENV JAVA_DIR=/usr/local
    ENV TZ=Asia/Shanghai
    # 拷贝jdk和java项目的包
    COPY ./jdk8.tar.gz $JAVA_DIR/
    COPY ./docker-demo.jar /tmp/app.jar
    # 设定时区
    RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
    # 安装JDK
    RUN cd $JAVA_DIR \
    && tar -xf ./jdk8.tar.gz \
    && mv ./jdk1.8.0_144 ./java8
    # 配置环境变量
    ENV JAVA_HOME=$JAVA_DIR/java8
    ENV PATH=$PATH:$JAVA_HOME/bin
    # 指定项目监听的端口
    EXPOSE 8080
    # 入口，java项目的启动命令
    ENTRYPOINT ["java", "-jar", "/app.jar"]

如果只想打包Java项目，可以直接引入包含JDK的基础镜像

    # 基础镜像
    FROM openjdk:11.0-jre-buster
    # 设定时区
    ENV TZ=Asia/Shanghai
    RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
    # 拷贝jar包
    COPY docker-demo.jar /app.jar
    # 入口
    ENTRYPOINT ["java", "-jar", "/app.jar"]

把dockerfile放在当前目录下，运行

    docker build -t docker-demo:1.0 .

以构建项目，`-t`是当前镜像的dockerfile名称:版本号，`.`代表在当前目录查找dockerfile

## 网络

通过以下命令查看容器内的mysql在容器内运行的IP

    docker inspect --format='{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' mysql

默认情况下，Docker 容器会加入到一个叫 bridge 的虚拟网桥（通常是 docker0）里。每个容器会分配一个虚拟 IP（通常是 172.17.x.x 段）。在 同一个 bridge 网络 下，容器之间可以直接通过 容器 IP:端口 访问彼此的服务（前提是服务监听在 0.0.0.0 或容器 IP 上，而不是 127.0.0.1）。

容器的网络IP其实是一个虚拟的IP，其值并不固定与某一个容器绑定，容器 IP 是动态分配的，不稳定

需要让不同程序上的服务通过socket相互访问，需要用到docker的网络功能

创建网络，指定网络名称

    docker network create net_name

让不同容器加入同一个网络

    docker network connect net_name container1 --alias c1
    docker network connect net_name container2 --alias c2

也可以在创建容器docker run时，加上 --network net_name在创建时连接

在同一个网络下，不同的容器相互通信不需要指定不稳定的IP地址，可以之间使用容器名称或别名（类似域名）

注意，同一个network下不同container相互通信使用的是容器内端口

    ping container1
    ping c2

一个容器加入的网络可以再inspect的.NetworkSettings.Networks部分看到

一个网络内的容器也可以在其inspect看到

    docker network inspect <network_name>

## docker compose

docker-compose文件中可以定义多个相互关联的应用容器，每一个应用容器被称为一个服务（service）。由于service就是在定义某个应用的运行时参数。可以在一个yaml文件内配置多个容器

|docker run 参数|docker compose 指令|说明|
|---------------|------------------|----|
|--name|container_name|容器名称|
|-p|ports|端口映射|
|-e|environment|环境变量|
|-v|volumes|数据卷配置|
|--network|networks|网络|

在一个yaml内

    version: "3.8"

    services:
        mysql:
            image: mysql
            container_name: mysql
            ports:
                - "3306:3306"
            environment:
                TZ: Asia/Shanghai
                MYSQL_ROOT_PASSWORD: 123
            volumes:
                - "./mysql/conf:/etc/mysql/conf.d"
                - "./mysql/data:/var/lib/mysql"
                - "./mysql/init:/docker-entrypoint-initdb.d"
            networks:
                - net
        mall:
            build: 
                context: .
                dockerfile: Dockerfile
            container_name: mall
            ports:
                - "8080:8080"
            networks:
                - net
            depends_on:
                - mysql
        nginx:
            image: nginx
            container_name: nginx
            ports:
                - "18080:18080"
                - "18081:18081"
            volumes:
                - "./nginx/nginx.conf:/etc/nginx/nginx.conf"
                - "./nginx/html:/usr/share/nginx/html"
            depends_on:
                - mall
            networks:
                - net
        networks:
            net:
                name: mall-net

重点是depends_on，表示不同容器的依赖顺序，被依赖的容器会先创建

在networks里的net是compose文件内部的引用名称，name: mall-net才是实际的网络名称

操作docker compose

    docker compose [OPTIONS] [COMMAND]

OPTIONS的-f可以指定docker compose的文件路径和名称

COMMAND的up是创建并且启动所有容器

如果只是简单的创建容器，写法是`docker compose up -d`，-d是后台启动
