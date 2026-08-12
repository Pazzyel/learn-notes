# 服务保护

级联失效或者叫雪崩问题，是因为下游服务的响应时间变慢或者阻塞导致上游的服务也响应时间变慢或阻塞的问题，问题随着调用链向上传播，影响大量服务

微服务保护的方案有很多，比如：

- 请求限流：限制或控制接口访问的并发流量，消去QPS的高峰
- 线程隔离：避免某个接口故障或压力过大导致整个服务不可用，限定每个接口可以使用的资源范围
- 服务熔断：统计服务提供方的异常比例，比例过高表明会影响到其它服务，应拒绝调用该接口，直接走降级逻辑，如返回某些提示

都属于服务降级的方案，但提高了健壮性

## Sentinel

Sentinel是一种微服务保护框架，可以在<https://github.com/alibaba/Sentinel/releases>下载jar包

    java -Dserver.port=8090 -Dcsp.sentinel.dashboard.server=localhost:8090 -Dproject.name=sentinel-dashboard -jar sentinel-dashboard.jar

启动sentinel服务，如果使用PowerShell，请把每项参数用单引号''括起来，在哪个端口启动服务就在哪里访问控制页面。默认账号密码都是sentinel

在项目中连接sentinel服务先引入依赖

    <!--sentinel-->
    <dependency>
        <groupId>com.alibaba.cloud</groupId> 
        <artifactId>spring-cloud-starter-alibaba-sentinel</artifactId>
    </dependency>

再在配置文件application.yaml配置

    spring:
      cloud: 
        sentinel:
          transport:
            dashboard: localhost:8090

但默认情况下Sentinel会把路径作为簇点资源的名称，无法区分路径相同但请求方式不同的接口，GET、DELETE、PUT等都被识别为一个簇点资源

如果需要分辨请求类型，应该加上

    spring:
      cloud:
        sentinel:
          transport:
            dashboard: localhost:8090
          http-method-specify: true # 开启请求方式前缀

### 请求限流

在簇点链路后面点击流控按钮，即可对其做限流配置，比如限制QPS

### 线程隔离

比如，查询购物车的时候需要查询商品，为了避免因商品服务出现故障导致购物车服务级联失败，我们可以把购物车业务中查询商品的部分隔离起来限制其使用的资源数

查询商品是通过OpenFeign的RPC调用，因此要对查询商品的FeignClient接口做线程隔离

在application.yaml配置开启feign的sentinel功能

    feign:
      sentinel:
        enabled: true # 开启feign对sentinel的支持

此时，就可以在Sentinel的簇点链路看到FeignClient会作为一个簇点资源，对这个簇点资源限流（线程数）就可以限制查询购物车这个接口使用的线程资源

### 服务熔断

降级处理逻辑：在某个接口因为限流导致无法调用时应该怎么做，比如抛异常，返回提示，返回可以查到的信息等

熔断：如果某个调用过程中接口响应时间很长，会拖慢上级访问的响应时间，此时直接不调用这个接口，走降级处理

#### 添加降级处理逻辑

需要编写对应工厂类，返回失败时的对应Feign接口的失败实现

其实现了FallbackFactory\<T>接口，工厂类必须返回一个T的实现类用作失败实现，实现的`create()`方法返回这个失败实现类

    @Slf4j
    public class ItemClientFallback implements FallbackFactory<ItemClient> {
        //FallbackFactory<T>工厂类必须返回一个T的实现类用作失败实现
        @Override
        public ItemClient create(Throwable cause) {
            return new ItemClient() {

                @Override
                public List<ItemDTO> queryItemByIds(Collection<Long> ids) {
                    log.error("RPC调用ItemClient.queryItemByIds()方法异常， ids={}", ids);
                    //查询商品的失败情况应该返回空List
                    return CollUtils.emptyList();
                }

                @Override
                public void deductStock(List<OrderDetailDTO> items) {
                    //扣减库存应该抛出业务异常触发事务回滚
                    throw new BizIllegalException(cause);
                }
            }
        }
    }

还要把这个失败处理工厂类注册成Bean让Spring能够将其用于自动装配

理论上也可以在原始的工厂类加上@Component，但是我们这个模块只是一个API模块，没有@SpringBootApplication来扫描包和注册Bean，具体写成这样的原因在下面介绍

    public class ItemFeignConfig {

        //把失败处理工厂类注册成Bean
        @Bean
        public ItemClientFallback itemClientFallback() {
            return new ItemClientFallback();
        }
    }

最后在该服务提供的RPC调用Client接口类的注解配置fallbackFactory这一项配置异常实现的工厂类

`configuration`必须指定，业务Spring Cloud OpenFeign会在为这个FeignClient创建代理时，额外加载指定的XxxConfig，然后从里面找需要的Bean（比如 Logger.Level、Contract、Decoder、Encoder、ErrorDecoder，以及手工注册的 fallback，这也是为什么必须在配置类注册成Bean而不是使用@Component，因为这种方法只会从对应的配置类注册Bean）。ItemFeignConfig 里的 @Bean 方法只会对 这个 FeignClient 生效

理论上也可以在调用这个Feign的微服务的启动类配置包扫描，但是耦合度高，不推荐

    @FeignClient(value = "item-service", configuration = {DefaultFeignConfig.class, ItemFeignConfig.class}, fallbackFactory = ItemClientFallback.class)

另一种方法是直接把异常实现类实现同样的ItemClient接口，此时就不用指定工厂类，而是fallback直接指定这个异常实现类

    @FeignClient(value = "item-service", configuration = {DefaultFeignConfig.class, ItemFeignConfig.class}, fallback = ItemClientFallback.class)

#### 熔断

对应异常的接口，Sentinel中的断路器不仅可以统计某个接口的慢请求比例，还可以统计异常请求比例。当这些比例超出阈值时，就会熔断该接口

断路器是一个状态机，包含以下部分

![断路器](/cloud-imgs/image3.png)

- closed：关闭状态，断路器放行所有请求，并开始统计异常比例、慢请求比例。超过阈值则切换到open状态
- open：打开状态，服务调用被熔断，访问被熔断服务的请求会被拒绝，快速失败，直接走降级逻辑。Open状态持续一段时间后会进入half-open状态
- half-open：半开状态，放行一次请求，根据执行结果来判断接下来的操作。
  - 请求成功：则切换到closed状态
  - 请求失败：则切换到open状态

在Sentinel控制台通过点击簇点链路的熔断按钮来配置熔断策略

- 最大RT：超过这个值的是慢请求
- 比例阈值：慢请求比例超过这个值触发熔断
- 熔断时长：从open到第一次half-open的时长
- 统计时长：统计到最近这个时长内的请求
- 最小请求数：在统计时长内最少需要的请求数目，小于这个值就是比例超过也不会熔断
