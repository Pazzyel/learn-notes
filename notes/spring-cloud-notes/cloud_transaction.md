# 分布式事务

分布式事务问题产生的一个重要原因，就是参与事务的多个分支事务互相无感知，不知道彼此的执行状态

解决方法是找一个统一的事务协调者，与多个分支事务通信，检测每个分支事务的执行状态，保证全局事务下的每一个分支事务同时成功或失败即可

Seata是一款开源的分布式事务框架，包括三部分

![Seata](/cloud-imgs/image4.png)

- TC (Transaction Coordinator) - 事务协调者：维护全局和分支事务的状态，协调全局事务提交或回滚。
- TM (Transaction Manager) - 事务管理器：定义全局事务的范围、开始全局事务、提交或回滚全局事务。
- RM (Resource Manager) - 资源管理器：管理分支事务，与TC交谈以注册分支事务和报告分支事务的状态，并驱动分支事务提交或回滚

## 部署TC服务

TC服务是单独的服务端，需要单独部署，为了持久化需要一般选择基于数据库存储，需要在数据库建立三张表，全局事务-->分支事务-->全局锁，对应表global_table、branch_table、lock_table

具体的SQL可以在<https://github.com/apache/incubator-seata/tree/master/script/server/db>下载

创建表之后，再创建一个资源目录，包括application.yaml（配置了nacos，mysql的地址，如果服务有异常可能是这里配置错了，可以在容器的logs查看）等，这个将被挂载到容器的resources目录

使用docker部署项目

    docker run --name seata \
    -p 8099:8099 \
    -p 7099:7099 \
    -e SEATA_IP=172.28.224.1 \
    -v ./seata:/seata-server/resources \
    --privileged=true \
    --network mallnet \
    -d \
    seataio/seata-server:1.5.2

注意，SEATA_IP 选项表示指定seata-server启动的IP, 该IP用于向注册中心注册时使用。如果在启动时将该参数设置为 -e SEATA_IP=localhost，那么seata-server 向 nacos 注册中心报告的地址则是seata-server 在 docker 中运行的地址

在WSL上测试部署时，应该将参数设置为 -e SEATA_IP=WSL主机地址。那么，此时在宿主机中微服务拿到的就是宿主机地址，因为宿主机和 docker 容器之间实现了端口映射，所以宿主机可以通过“宿主机 ip 地址:端口”的形式访问到 TC 服务

## 微服务集成Seata

依赖的服务：MySQL，Nacos，Seata，Sentinel

为了方便各个微服务集成seata，我们需要把seata配置共享到nacos，因此模块不仅仅要引入seata依赖，还要引入nacos依赖

    <!--nacos统一配置管理-->
    <dependency>
        <groupId>com.alibaba.cloud</groupId>
        <artifactId>spring-cloud-starter-alibaba-nacos-config</artifactId>
    </dependency>
    <!--读取bootstrap文件-->
    <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-starter-bootstrap</artifactId>
    </dependency>
    <!--seata-->
    <dependency>
        <groupId>com.alibaba.cloud</groupId>
        <artifactId>spring-cloud-starter-alibaba-seata</artifactId>
    </dependency>

因此在nacos中配置seata的共享配置，命名为shared-seata.yaml

    seata:
      registry: # TC服务注册中心的配置，微服务根据这些信息去注册中心获取tc服务地址
        type: nacos # 注册中心类型 nacos
        nacos:
          server-addr: 172.28.244.1:8848 # nacos地址
          namespace: "" # namespace，默认为空
          group: DEFAULT_GROUP # 分组，默认是DEFAULT_GROUP
          application: seata-server # seata服务名称
          username: nacos
          password: nacos
    tx-service-group: hmall # 事务组名称
    service:
      vgroup-mapping: # 事务组与tc集群的映射关系
        hmall: "default"

在所有需要使用分布式事务的服务的bootstrap.yaml拉取对应配置

    spring:
      cloud:
        nacos:
          server-addr: 172.28.224.1:8848
          config:
            file-extension: yaml # 文件后缀名
            shared-configs: # 共享配置
              - dataId: shared-seata.yaml # 共享Seata配置，分布式事务

对应Seata操作事务需要对应的数据库内存在一张undolog表用于记录分布式事务的中间数据，建表操作SQL可以在<https://github.com/apache/incubator-seata/tree/master/script/client/at/db>获取

需要分布式事务操作的数据库都有了undolog表后就可以实现分布式事务操作

使用`@GlobalTransactional`注解标识这个方法是一个分布式事务方法，无论是本地调用还是RPC调用都会有事务特性

如果在全局事务执行的过程中发生异常，可以查看Seata的TC端的控制台日志查看，也可以访问TC端的网页管理页面，通常情况下如果没有单独配置，微服务连接Seata的端口是网页管理页面端口+1000，因此如果在docker运行，需要映射两个端口

### XA模式

XA规范，实现的原理基于两阶段提交

一阶段：

- 事务协调者通知每个事务参与者执行本地事务
- 本地事务执行完成后报告事务执行状态给事务协调者，此时事务不提交，继续持有数据库锁

二阶段：

- 事务协调者基于一阶段的报告来判断下一步操作
- 如果一阶段都成功，则通知所有事务参与者，提交事务
- 如果一阶段任意一个参与者失败，则通知所有事务参与者回滚事务

对于Seata，事务执行者是微服务RM，事务协调者是TC，TC根据所有RM报告的状态给RM发送提交/回滚指令

优点

- 事务的强一致性，满足ACID原则
- 常用数据库都支持，实现简单，并且没有代码侵入

缺点

- 因为一阶段需要锁定数据库资源，等待二阶段结束才释放，性能较差
- 依赖关系型数据库实现事务

要配置Seata为XA模式，只需要修改`shared-seata.yaml`这个Nacos共享的配置

    seata:
      data-source-proxy-mode: XA

### AT模式

AT是Seata默认的模式

AT和XA类似，不过每个事务参与者执行完SQL后先记录undo log，随后立刻提交事务给数据库（释放数据库锁），不等待事务协调者发通知。如果出现异常，事务参与者给事务协调者发消息，事务协调者再给每个事务参与者发送回滚命令，此时所有事务参与者根据undo log恢复到事务执行前的数据

和XA相比，单个本地事务执行完立刻提交释放锁，并发性能更好，且也保证了最终一致
