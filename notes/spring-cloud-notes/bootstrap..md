# bootstrap

## 问题来源

读取注册中心配置是SpringCloud上下文（ApplicationContext）初始化时处理的，发生在项目的引导阶段。然后才会初始化SpringBoot上下文，去读取application.yaml。而没有读取application.yaml就不知道注册中心地址，无法拉取配置

## 解决方案bootstrap.yaml

因此，Spring Cloud早期版本中，Spring Cloud在初始化上下文的时候会先读取一个名为bootstrap.yaml(或者bootstrap.properties)的文件，如果我们将注册中心地址配置到bootstrap.yaml中，在项目引导阶段就可以读取注册中心中的配置

## 原理

Spring Cloud 启动时，先创建一个 Bootstrap Context（父上下文），加载 bootstrap.yml 中的配置。读取配置中心信息如 spring.cloud.config.uri，或者 spring.cloud.nacos.config.server-addr等，从远程配置中心获取配置，并把远程的配置内容放入 Environment 中。再创建主应用上下文 (ApplicationContext)，加载 application.yml，此时可以使用上一步从远程加载的配置。

在bootstrap中的配置会先加载到Bootstrap Environment，最后合并到主Environment，因此理论上，可以在bootstrap中配置所有的配置项，但实际中并不推荐这么做

bootstrap的读取过程中，spring.profiles.active处于没有被解析的状态（在ApplicationContext加载时才解析），因此bootstrap不会触发profile切换，也无法读取其它profile的文件信息，只能写死配置

使用bootstrap的最佳实践是

- Bootstrap阶段：只配置应用引导配置，是在上下文创建前就必须知道的东西，比如配置中心地址、命名空间、加密密钥、注册中心连接信息等
- Application 阶段：应用业务配置，是应用运行时需要的参数，比如端口、数据库连接、日志级别、业务参数

## 新版本的变化

Spring Boot 2.4+/Spring Cloud 2020+，在这个新版本之后，bootstrap.yaml 被废弃，取而代之的是新的 spring.config.import机制

比如原本为了从注册中心拉取配置，必须在bootstrap.yaml写

```yaml
spring:
  application:
    name: trade-service
  profiles:
    active: dev
  cloud:
    nacos:
      server-addr: 127.0.0.1:8848
      config:
        file-extension: yaml
        shared-configs:
          - dataId: shared_jdbc.yaml
          - dataId: shared_log.yaml
          - dataId: shared_feign.yaml
          - dataId: shared-sentinel.yaml
          - dataId: shared-seata.yaml
          - dataId: shared-rabbitmq.yaml
```

新版本不需要bootstrap，直接在application.yaml配置注册中心地址，并使用spring.config.import从注册中心导入需要的配置

```yaml
spring:
  application:
    name: trade-service
  profiles:
    active: dev
  cloud:
    nacos:
      server-addr: 172.28.224.1:8848
      config:
        file-extension: yaml
  config:
    import:
      - optional:nacos:trade-service-dev.yaml?refresh=true
      - optional:nacos:shared_jdbc.yaml?refresh=true
      - optional:nacos:shared_log.yaml?refresh=true
      - optional:nacos:shared_feign.yaml?refresh=true
      - optional:nacos:shared-sentinel.yaml?refresh=true
      - optional:nacos:shared-seata.yaml?refresh=true
      - optional:nacos:shared-rabbitmq.yaml?refresh=true
```

- spring.config.import: 告诉 Spring Boot：除了本地 application.yml，还要从 nacos 导入配置
- optional: Nacos 不可用时不影响启动
- nacos:xxx.yaml: 指定要加载的 dataId
- ?refresh=true: 配合 @RefreshScope(注解在需要@Value注入动态属性的类) 支持动态刷新
- spring.cloud.nacos.server-addr: 告诉 Spring 哪里有 Nacos 服务
