# MQ高级

消息应该至少被消费者处理1次，这需要

- 确保生产者一定把消息发送到MQ
- 确保MQ不会将消息弄丢
- 确保消费者一定要处理消息

## 生产者的可靠性

确保生产者一定把消息发送到MQ

思考TCP连接如何保证连接的可靠性？

- 发送报文需要ACK（ACK号是下一个需要的报文序号）
- 没有ACK时重传

生产者发送消息的可靠性也可以用这种机制

注意：开启生产者确认比较消耗MQ性能，而且生产者发送失败的情况很少见，一般不建议开启，要开启也只建议开启Confirm Callback（ACK/NACK）

### 重传

生产者可能无法连接到MQ

SpringAMQP提供的消息发送时的重试机制。即：当RabbitTemplate与MQ连接超时后，多次重试

```yaml
spring:
  rabbitmq:
    connection-timeout: 1s # 设置MQ的连接超时时间
    template:
      retry:
        enabled: true # 开启超时重试机制
        initial-interval: 1000ms # 失败后的初始等待时间
        multiplier: 1 # 失败后下次的等待时长倍数，下次等待时长 = initial-interval * multiplier
        max-attempts: 3 # 最大重试次数
```

SpringAMQP提供的重试机制是阻塞式的重试，重试时业务阻塞

如果业务性能有要求，应该禁用重试机制或使用多线程异步进行

### 确认（生产者ACK）

RabbitMQ提供了生产者消息确认机制，包括Publisher Confirm（ACK，NACK）和Publisher Return（return）两种

- 当消息投递到MQ，但是exchange路由失败时，通过Publisher Return返回异常信息，同时返回ack的确认信息，代表投递成功
- 临时消息投递到了MQ，并且入队成功，返回ACK，告知投递成功
- 持久消息投递到了MQ，并且入队完成持久化，返回ACK ，告知投递成功
- 其它情况都会返回NACK，告知投递失败

需要启用生产者确认，请在配置文件配置

```yaml
spring:
  rabbitmq:
    publisher-confirm-type: correlated # 开启publisher confirm机制，并设置confirm类型
    publisher-returns: true # 开启publisher return机制
```

其中confirm类型有三种，推荐使用correlated

- none：关闭confirm机制
- simple：同步阻塞等待MQ的回执
- correlated：MQ异步回调返回回执

#### 配置Return Callback

ReturnCallback是响应式编程的范例，配置类提供Return Callback触发时需要进行的逻辑操作定义，配置时实现`RabbitTemplate.ReturnsCallback`的`void returnedMessage(ReturnedMessage returned)`方法设置Return Callback的逻辑，并用`rabbitTemplate.setReturnsCallback()`把匿名内部实现类配置到RabbitTemplate

一个RabbitTemplate只能配置一个ReturnCallback，Spring默认的Bean是单例的，因此必须在一个统一的模块配置ReturnCallback

当MQ回调的Publisher Return到达时，ReturnCallback做出对应的响应

```java
@Slf4j
@AllArgsConstructor
@Configuration
public class MqConfig {
    private final RabbitTemplate rabbitTemplate;

    @PostConstruct
    public void init(){
        rabbitTemplate.setReturnsCallback(new RabbitTemplate.ReturnsCallback() {
            @Override
            public void returnedMessage(ReturnedMessage returned) {
                log.error("触发return callback,");
                log.debug("exchange: {}", returned.getExchange());
                log.debug("routingKey: {}", returned.getRoutingKey());
                log.debug("message: {}", returned.getMessage());
                log.debug("replyCode: {}", returned.getReplyCode());
                log.debug("replyText: {}", returned.getReplyText());
            }
        });
    }
}
```

#### 配置Confirm Callback

消息发送到路由失败时，不同消息需要的处理逻辑不同，不能统一配置。因此ConfirmCallback需要在每次发消息时携带

`convertAndSend()`方法有多一个参数的重载版本，多出来的参数CorrelationData就是消息的额外信息

```java
convertAndSend(String, String, Object, CorrelationData)
```

CorrelationData包含两个核心：

- id：消息的唯一标示，MQ对不同的消息的回执以此做判断，避免混淆
- SettableListenableFuture：回执结果的Future对象，将在未来被RabbitMQ ACK/NACK后执行其回调逻辑

对这个Future对象使用`addCallback()`添加`ListenableFutureCallback`类来添加Future就绪后的回调逻辑

```java
@Test
void testPublisherConfirm() {
    // 1.创建CorrelationData
    CorrelationData cd = new CorrelationData();
    // 2.给Future添加ConfirmCallback
    cd.getFuture().addCallback(new ListenableFutureCallback<CorrelationData.Confirm>() {
        @Override
        public void onFailure(Throwable ex) {
            // 2.1.Future发生异常时的处理逻辑，基本不会触发
            log.error("send message fail", ex);
        }
        @Override
        public void onSuccess(CorrelationData.Confirm result) {
            // 2.2.Future接收到回执的处理逻辑，参数中的result就是回执内容
            if(result.isAck()){ // result.isAck()，boolean类型，true代表ack回执，false 代表 nack回执
                log.debug("发送消息成功，收到 ack!");
            }else{ // result.getReason()，String类型，返回nack时的异常描述
                log.error("发送消息失败，收到 nack, reason : {}", result.getReason());
            }
        }
    });
    // 3.发送消息
    rabbitTemplate.convertAndSend("hmall.direct", "q", "hello", cd);
}
```

此时我们测试时如果发送的routeKey错误，MQ可以收到消息但不能路由，就会同时发生Return Callback和Confirm Callback，执行Return Callback配置的回调操作和Confirm Callback中ACK对应的回调操作

## MQ的可靠性

默认MQ数据和Redis一样储存在内存，重启丢失，可以通过配置把数据持久化到硬盘

### 交换机，队列的持久化

在管理页面的`Add a new Exchange/Queue`可以设置交换机或者队列的`Durability`参数，设置为`Durable`就是持久化模式

### 消息的持久化

在控制台向队列/交换机发消息，把Delivery mode选择为`Persistent`就是持久化的

使用`RabbitTemplate`在Java程序发消息，默认就是持久化的，如果想要以非持久化的方法发消息，应该使用`MessageBuilder`的`setDeliveryMode(MessageDeliveryMode.NON_PERSISTENT)`构建非持久化的消息

```java
Message message = MessageBuilder.withBody("Hello, Spring AMQP".getBytes(StandardCharsets.UTF_8))
    .setDeliveryMode(MessageDeliveryMode.NON_PERSISTENT).build();
```

在开启持久化机制以后，如果同时还开启了生产者确认，那么MQ会在消息持久化以后才发送ACK，进一步确保消息的可靠性

不过出于性能考虑，为了减少IO次数，发送到MQ的消息并不是逐条持久化的，而是每隔一段时间批量持久化。一般间隔在100毫秒左右，导致ACK有一定的延迟，因此建议生产者确认全部采用异步方式

### LazyQueue

早期版本RabbitMQ将消息存储在内存中，当因某些原因（消费者消费不及时，生产者产出过快）导致消息积压时，内存占用过大触发告警，RabbitMQ会将内存消息刷到磁盘上（PageOut）， PageOut会耗费一段时间，并且会阻塞队列进程。因此在这个过程中RabbitMQ不会再处理新的消息，生产者的所有请求都会被阻塞

RabbitMQ的3.6.0版本开始，就增加了Lazy Queues模式，接收消息直接写入硬盘，要消费时才从硬盘读取并加载，此时会提高消息收发的延迟，但可以存储大量消息。3.12版本之后，LazyQueue已经成为所有队列的默认格式

3.12版本之前，可以在`Add a new Queue`选择Lazy mode，（arguments: x-queue-mode=lazy）

在Spring AMQP配置Lazy模式的Queue对象

```java
@Bean
public Queue lazyQueue() {
    Queue queue = QueueBuilder.durable("lazy.queue").lazy().build();
}
```

也可以直接在通过消费者的`@RabbitListener`注解创建lazy模式的Queue，直接配置注解的`queuesToDeclare`参数

```java
@RabbitListener(queuesToDeclare = @Queue(
        name = "lazy.queue",
        durable = "true",
        arguments = @Argument(name = "x-queue-mode", value = "lazy")
))
public void listenLazyQueue(String msg){
    log.info("接收到 lazy.queue的消息：{}", msg);
}
```

如果想要把原有的队列修改为Lazy模式，需要使用命令行设置policy

```shell
rabbitmqctl set_policy Lazy "^lazy-queue$" '{"queue-mode":"lazy"}' --apply-to queues  
```

- set_policy：设置策略
- Lazy ：策略名称，可以自定义
- "^lazy-queue$" ：用正则表达式匹配队列的名字
- '{"queue-mode":"lazy"}' ：设置队列模式为lazy模式
- --apply-to queues：策略的作用对象，是所有的队列

或者在管理页面的Admin的Policies选择Add / update a policy，图形化界面操作

## 消费者可靠性

如果MQ接收到一条消费请求后就把队列尾部的消息移除，而消费者因为某些原因请求了但没有正常读取到消息或者处理消息时发生移异常，那么这条消息既没有被成功消费，也没有保存在MQ，也就是丢失了

解决问题的核心就是保证MQ能知道消费者正确读到了消息，没有时没有重新发送，这也可以利用ACK的机制

### 消费者确认机制

RabbitMQ提供了消费者确认机制，当消费者处理消息结束后，应该向RabbitMQ发送一个回执，告知RabbitMQ自己消息处理状态。回执有三种可选值

- ack：成功处理消息，RabbitMQ从队列中删除该消息
- nack：消息处理失败，RabbitMQ需要再次投递消息
- reject：消息处理失败并拒绝该消息，RabbitMQ从队列中删除该消息，一般开发少用

Spring AMQP提供了几种消费者发送ACK回执的模式

- none：无处理直接ACK，即消息投递给消费者后立刻ack，消息会立刻从MQ删除。非常不安全
- manual：手动ACK。需要自己在业务代码中调用api，发送ack或reject，存在业务入侵，但更灵活
- auto：自动模式。SpringAMQP利用AOP实现，当业务正常执行时则自动返回ack. 当业务出现异常，根据异常判断返回不同结果：
  - 如果是业务异常，会自动返回nack
  - 如果是消息处理或校验异常，自动返回reject

在auto模式中，返回reject的异常有AMQP的`MessageConversionException``MessageConversionException``MethodArgumentNotValidException``MethodArgumentTypeMismatchException`和Java的`NoSuchMethodException``ClassCastException`

通过在配置文件中修改发送ACK回执的模式

```yaml
spring:
  rabbitmq:
    listener:
      simple:
        acknowledge-mode: none # 不做处理
```

MQ对处理nack的方法一般是把这个消息重新入队列

### 失败重试机制

如果消费者收到一个它处理时会有异常的消息，就会返回nack，再次收到时还是重复

处理nack，重入队列的极端情况就是消费者一直无法执行成功，那么消息requeue就会无限循环，导致mq的消息处理飙升

Spring提供了消费者失败重试机制：在消费者出现异常时利用本地重试，而不是发送nack，无限制的requeue到mq队列

本地重试就是本地保存这个消息，消费者处理失败时重新人消费者读取本地的消息尝试再次处理，有最大重试次数

在配置文件配置如下内容开启本地重试

```yaml
spring:
  rabbitmq:
    listener:
      simple:
        retry:
          enabled: true # 开启消费者失败重试
          initial-interval: 1000ms # 初识的失败等待时长为1秒
          multiplier: 1 # 失败的等待时长倍数，下次等待时长 = multiplier * last-interval
          max-attempts: 3 # 最大重试次数
          stateless: true # true无状态；false有状态。如果业务中包含事务，这里改为false
```

超过最大重试次数还是失败，抛出`AmqpRejectAndDontRequeueException`异常，auto模式对这个异常的行为是发送reject到MQ

### 自定义失败处理逻辑

默认情况下达到最大重试后发送reject，消息会被丢弃

Spring允许我们自定义重试次数耗尽后的消息处理策略，由MessageRecovery接口来定义的，它有3个不同实现：

- RejectAndDontRequeueRecoverer：重试耗尽后，直接reject，丢弃消息（默认）
- ImmediateRequeueMessageRecoverer：重试耗尽后，返回nack，消息重新入队
- RepublishMessageRecoverer：重试耗尽后，将失败消息投递到指定的交换机

其中，`RepublishMessageRecoverer`的用法如下

声明我们在处理失败时需要投递的交换机/队列

```java
@Bean
public DirectExchange errorMessageExchange(){
    return new DirectExchange("error.direct");
}
@Bean
public Queue errorQueue(){
    return new Queue("error.queue", true);
}
@Bean
public Binding errorBinding(Queue errorQueue, DirectExchange errorMessageExchange){
    return BindingBuilder.bind(errorQueue).to(errorMessageExchange).with("error");
}
```

定义一个`RepublishMessageRecoverer`，包括失败时投递到的交换机名称和RoutingKey

```java
@Bean
public MessageRecoverer republishMessageRecoverer(RabbitTemplate rabbitTemplate){
    return new RepublishMessageRecoverer(rabbitTemplate, "error.direct", "error");
}
```

这样在达到最大重试次数后，就会把这个交换机以`error`的RoutingKey投递到`error.direct`

### 确保幂等性的方案

由于MQ重投消息机制的存在，可能出现消息被多次投放的情况，有些业务不是幂等的，多次投放可能出现业务异常

保证消息处理的幂等性，可以有两种方案

#### 唯一消息ID

方案很简单，给消息的内容添加一个唯一的ID，消费者保存这个ID，下次接收相同ID的消息时直接丢弃这个消息，不消费

可以直接使用SpringAMQP的MessageConverter自带的MessageID的功能，在序列化消息时自动添加MessageID

```java
@Bean
public MessageConverter messageConverter(){
    // 1.定义消息转换器
    Jackson2JsonMessageConverter jackson2JsonMessageConverter = new Jackson2JsonMessageConverter();
    // 2.配置自动创建消息id，用于识别不同消息，也可以在业务中基于ID判断是否是重复消息
    jackson2JsonMessageConverter.setCreateMessageIds(true);
    return jackson2JsonMessageConverter;
}
```

在接收消息的拦截器添加判断MessageID的逻辑，这里假设已经消费的MessageID存在Redis，也可以直接存在数据库（如message_log表）

```java
//接收消息时解析MessageID
@Bean
public MethodInterceptor userIdInterceptor() {
    return invocation -> {
        boolean newMessage = false;
        Object[] args = invocation.getArguments();
        for (Object arg : args) {
            if (arg instanceof Message) {
                Message message = (Message) arg;
                Long messageId = message.getMessageProperties().getMessageId();
                if (messageId != null) {
                    Boolean contained = redisTemplate.opsForSet().isMember("message:id",messageId);//假设存在Redis
                    if (!contained) {
                        newMessage = true;
                        redisTemplate.opsForSet().add("message:id",messageId);
                    }
                }
                break;
            }
        }
        if (newMessage) {
            return invocation.proceed();
        } else {
            return null;
        }
    };
}
```

#### 业务判断

直接根据业务情况判断是不是重复消息

例如，某个消息，处理的业务逻辑是把订单状态从未支付修改为已支付。那么就可以在执行业务时判断订单状态是否是未支付，如果不是则证明订单已经被处理过，无需重复处理

注意这个案例的 查询 + 更新 必须写在同一条SQL（或者查询用SELECT FOR UPDATE），不然会有线程安全问题

```SQL
UPDATE `order` SET status = 2 , pay_time = #{now} WHERE id = #{orderId} AND status = 1 # MyBatis的写法
```

如果用MybatisPlus可以这样写

```java
@Override
public void markOrderPaySuccess(Long orderId) {
    LocalDateTime now = LocalDateTime.now();
    lambdaUpdate().set(Order::getStatus, 2).set(Order::getPayTime,now).set(Order::getUpdateTime,now)
            .eq(Order::getId, orderId).eq(Order::getStatus, 1).update();
}
```

### 兜底方案

如果MQ的通知真的失败，兜底方案应该是消费者主动向生产者查询消息的内容

比如支付服务是生产者，用户支付成功时生产支付成功消息；订单服务是消费者，收到消息时修改订单状态为已支付

如果订单服务迟迟没有收到消息，可以直接向生产者查询支付状态（例如OpenFeign同步调用），不经过MQ，因此不受MQ异常的影响，可以作为兜底方案

主动查询的时间应该怎么配置？一般利用定时任务定期主动查询

## 延迟消息

有一种场景，对于超过一定时间未支付的订单，应该立刻取消订单并释放占用的库存

也就是在下单后，过一段时间执行任务，取消这个订单

有一种方法是依靠定时任务，但定时任务频率太高影响性能，太低又会提高处理的延迟

可以用MQ的延迟消息功能解决

### 死信交换机和延迟消息

了解死信的概念，以下情况的消息称为死信（dead letter）：

- 处理失败而被拒绝的消息，且消息requene参数为false
- 因队列满了而被拒绝的消息
- TTL（有效期）到期的消息

队列中的某个消息如果已经成为死信，并且这个队列通过dead-letter-exchange属性指定了一个交换机，那么队列中的死信就会直接投递到这个交换机中，而这个交换机就称为死信交换机（Dead Letter Exchange）。如果有队列与死信交换机绑定，则最终死信就会被投递到这个队列中

前面的两种情况类似`RepublishMessageRecoverer`，处理消息处理失败的场景

后一种则可以用来达成延时消息，消息发到队列后五日消费，结果时间`expiration`后过期被投递到死信交换机，死信交换机更加routingKey投递到指定队列。这个队列收到的消息延迟了`expiration`

注意，RabbitMQ的消息的TTL到期以后不一定会被移除或投递到死信交换机，而是在**消息恰好处于队首时**才会被处理，因此实践延迟的时间很可能大于TTL

### DelayExchange插件

手动配置死信交换机达成延时消息的功能是比较麻烦的，DelayExchange插件设计了一种延迟交换机，交换机里的消息经过延时的时间之后才会被投递，使用更加方便

1. 从仓库地址下载指定版本的插件<https://github.com/rabbitmq/rabbitmq-delayed-message-exchange>
2. 查看之前创建容器挂载的volume，挂载的是容器内部的`/plugins`目录，使用命令`docker volume inspect mq-plugins`
   - 如果之前创建的时候忘记挂载了，或者用的Docker是Docker Desktop在WSL上，请手动使用`docker cp`，复制到容器内部的`/plugins`目录，另一种方法是运行`docker run -it --rm -v mq-plugins:/data busybox sh`把`/plugins`目录挂载到一个临时容器的`/data`目录并进入这个容器的终端
3. 运行命令加载插件`docker exec -it mq rabbitmq-plugins enable rabbitmq_delayed_message_exchange`

这样我们就可以使用延迟交换机的功能，在创建交换机的时候指定参数`delayed = "true"`使其成为延时交换机

如果要在Java创建延时交换机，有两种方法，它们的本质也只是添加了参数

根据`@RabbitListener`创建，在`@Exchange`添加注解属性`delayed = "true"`

```java
@RabbitListener(bindings = @QueueBinding(
        value = @Queue(name = "delay.queue", durable = "true"),
        exchange = @Exchange(name = "delay.direct", delayed = "true"),
        key = "delay"
))
public void listenDelayMessage(String msg){
    log.info("接收到delay.queue的延迟消息：{}", msg);
}
```

通过`@Bean`配置，调用`ExchangeBuilder`的`delayed()`方法

```java
@Bean
public DirectExchange delayExchange(){
    return ExchangeBuilder
            .directExchange("delay.direct") // 指定交换机类型和名称
            .delayed() // 设置delay的属性为true
            .durable(true) // 持久化
            .build();
}
```

向延时交换机发送消息，就必须指定`x-delay`属性，在Spring AMQP中可以在发消息的时候附加`MessagePostProcessor`参数，让字符串被转换成`Message`对象时设定`message.getMessageProperties().setDelay(5000);`，单位是ms

```java
rabbitTemplate.convertAndSend("delay.direct", "delay", message, new MessagePostProcessor() {
    @Override
    public Message postProcessMessage(Message message) throws AmqpException {
        // 添加延迟消息属性
        message.getMessageProperties().setDelay(5000);
        return message;
    }
});
```

那么要完成我们之前提到的：下单一段时间后删除没有支付的订单，具体方法就可以这么做

先定义常量，包括我们的延迟交换机名称，routingKey等

```java
public class MQConstants {
    public static final String DELAY_EXCHANGE_NAME = "trade.delay.direct";
    public static final String DELAY_ORDER_QUEUE_NAME = "trade.delay.order.queue";
    public static final String DELAY_ORDER_KEY = "delay.order.query";
}
```

然后在下单的操作中，添加发送延时消息的功能

```java
// 5.发送延迟消息，检查订单是否未支付
rabbitTemplate.convertAndSend(MQConstants.DELAY_EXCHANGE_NAME, MQConstants.DELAY_ORDER_KEY, order.getId(), message -> {
    message.getMessageProperties().setDelay(10000);
    return message;
});
```

然后应该添加消费者，但是消费者需要查询支付服务，我们之前并没有支付服务相关的RPC调用接口，因此先添加

首先是需要在不同服务传输的`PayOrderDTO`

```java
@Data
@ApiModel(description = "支付单数据传输实体")
public class PayOrderDTO {
    @ApiModelProperty("id")
    private Long id;
    @ApiModelProperty("业务订单号")
    private Long bizOrderNo;
    @ApiModelProperty("支付单号")
    private Long payOrderNo;
    @ApiModelProperty("支付用户id")
    private Long bizUserId;
    @ApiModelProperty("支付渠道编码")
    private String payChannelCode;
    @ApiModelProperty("支付金额，单位分")
    private Integer amount;
    @ApiModelProperty("支付类型，1：h5,2:小程序，3：公众号，4：扫码，5：余额支付")
    private Integer payType;
    @ApiModelProperty("支付状态，0：待提交，1:待支付，2：支付超时或取消，3：支付成功")
    private Integer status;
    @ApiModelProperty("拓展字段，用于传递不同渠道单独处理的字段")
    private String expandJson;
    @ApiModelProperty("第三方返回业务码")
    private String resultCode;
    @ApiModelProperty("第三方返回提示信息")
    private String resultMsg;
    @ApiModelProperty("支付成功时间")
    private LocalDateTime paySuccessTime;
    @ApiModelProperty("支付超时时间")
    private LocalDateTime payOverTime;
    @ApiModelProperty("支付二维码链接")
    private String qrCodeUrl;
    @ApiModelProperty("创建时间")
    private LocalDateTime createTime;
    @ApiModelProperty("更新时间")
    private LocalDateTime updateTime;
}
```

然后是RPC调用接口和fallback的相关配置

```java
@FeignClient(value = "pay-service", configuration = {DefaultFeignConfig.class, PayClientFallback.class}, fallbackFactory = PayClientFallback.class)
public interface PayClient {

    @GetMapping("/pay-orders/biz/{id}")
    PayOrderDTO queryPayOrderByBizOrderNo(@PathVariable("id") Long id);

    @PutMapping("/pay-orders/biz/{id}")
    boolean makePayOrderClose(@PathVariable("id") Long orderId);
}
```

```java
public class PayClientFallback implements FallbackFactory<PayClient> {
    @Override
    public PayClient create(Throwable cause) {
        return new PayClient() {
            @Override
            public PayOrderDTO queryPayOrderByBizOrderNo(Long id) {
                return null;
            }

            @Override
            public boolean makePayOrderClose(Long orderId) {
                return false;
            }
        };
    }
}
```

```java
@Configuration
public class PayFeignConfig {

    @Bean
    public PayClientFallback payClientFallback() {
        return new PayClientFallback();//返回的是Factory，所以直接返回原始类型
    }
    
}
```

还要在`PayController`实现这个RPC调用的接口

```java
@ApiOperation("通过业务订单号查询支付单")
@GetMapping("/biz/{id}")
public PayOrderDTO queryPayOrderByBizOrderNo(@PathVariable("id") Long id) {
    PayOrder payOrder = payOrderService.queryByBizOrderNo(id);
    return BeanUtils.copyBean(payOrder, PayOrderDTO.class);
}

@ApiOperation("通过业务订单号关闭支付单")
@PutMapping("/biz/{id}")
public boolean makePayOrderClose(@PathVariable("id") Long orderId) {
    log.info("关闭支付单，orderId {}",orderId);
    return payOrderService.makePayCloseByBizOrderId(orderId, LocalDateTime.now());
}
```

```java
public boolean makePayCloseByBizOrderId(Long orderId, LocalDateTime closeTime) {
    return lambdaUpdate()
            .set(PayOrder::getStatus, PayStatus.TRADE_CLOSED.getValue())
            .set(PayOrder::getPayOverTime, closeTime)
            .eq(PayOrder::getBizOrderNo, orderId)
            // 支付状态的乐观锁判断
            .in(PayOrder::getStatus, PayStatus.NOT_COMMIT.getValue(), PayStatus.WAIT_BUYER_PAY.getValue())
            .update();
}
```

最后就是编写消费者逻辑了

```java
@Slf4j
@Component
@RequiredArgsConstructor
public class OrderDelayMessageListener {

    private final IOrderService orderService;
    private final PayClient payClient;

    @RabbitListener(bindings = @QueueBinding(
            value = @Queue(name = MQConstants.DELAY_ORDER_QUEUE_NAME),
            exchange = @Exchange(name = MQConstants.DELAY_EXCHANGE_NAME, delayed = "true"),
            key = MQConstants.DELAY_ORDER_KEY
    ))
    public void listenOrderDelayMessage(Long orderId) {
        //先检查是否已支付
        Order order = orderService.getById(orderId);
        if (order == null || order.getStatus() != 1) {
            //订单不存在或者状态不是未付款时不处理
            return;
        }

        //再从支付服务获取支付消息
        PayOrderDTO payOrderDTO = payClient.queryPayOrderByBizOrderNo(orderId);
        if (payOrderDTO != null && payOrderDTO.getStatus() == 3) {
            //订单已付款
            orderService.markOrderPaySuccess(orderId);
            log.info("发现已支付订单未修改状态，已执行修改，orderId:{}", orderId);
        } else {
            boolean close = payClient.makePayOrderClose(orderId);
            if (!close) {
                //关闭支付单失败，说明用户在瞬间支付了
                return;
            }
            orderService.cancelOrder(orderId);
            log.info("发现支付超时订单，已取消，orderId:{}", orderId);
        }
    }
}
```

**注意**：这里要**先关闭支付单**，再关闭订单，防止关闭订单和关闭支付单之间用户支付造成的并发问题

其中的`cancelOrder()`方法我们之前没有实现，这里也需要在接口声明，在OrderServiceImpl添加方法，这里通过业务判断保证幂等性

```java
@Override
public void cancelOrder(Long orderId) {
    LocalDateTime now = LocalDateTime.now();
    //5是取消订单
    lambdaUpdate().set(Order::getStatus, 5).set(Order::getUpdateTime, now).set(Order::getCloseTime,now)
            .eq(Order::getId, orderId).eq(Order::getStatus, 1).update();
}
```

## RabbitMQ工具类

延时消息，带确认的消息每次都构建lambda比较麻烦，我们封装自己的RabbitMQ工具类

其中`sendDelayMessage()`方法发送延时消息，`sentMessageWithConfirm()`在消息发送到交换机没有ACK时重试指定的次数

```java
//这里不注册为Bean，有需要时用@Bean注册
@Slf4j
public class RabbitMQHelper {

    private RabbitTemplate rabbitTemplate;

    public RabbitMQHelper(RabbitTemplate rabbitTemplate) {
        this.rabbitTemplate = rabbitTemplate;
    }

    public void sendMessage(String exchangeName, String routingKey, Object messageBody) {
        rabbitTemplate.convertAndSend(exchangeName, routingKey, messageBody);
    }

    public void sendDelayMessage(String exchangeName, String routingKey, Object messageBody, int delay) {
        rabbitTemplate.convertAndSend(exchangeName, routingKey, messageBody, message -> {
            message.getMessageProperties().setDelay(delay);
            return message;
        });
    }

    public void sentMessageWithConfirm(String exchangeName, String routingKey, Object messageBody, int maxRetries) {
        CorrelationData correlationData = new CorrelationData(UUID.randomUUID().toString());
        correlationData.getFuture().addCallback(new ListenableFutureCallback<CorrelationData.Confirm>() {

            int retryCount = 0;

            @Override
            public void onSuccess(CorrelationData.Confirm result) {
                if (result != null && !result.isAck()) {
                    log.debug("消息发送失败，当前重试次数{}/{}", retryCount, maxRetries);
                    if (retryCount >= maxRetries) {
                        log.error("消息发送失败，重试次数耗尽");
                        return;
                    }
                    retryCount++;
                    CorrelationData cd = new CorrelationData(UUID.randomUUID().toString());
                    cd.getFuture().addCallback(this);//每次添加的CallBack都是同一个，retryCount自然也是同一个，这也是为什么我们不用lambda
                    rabbitTemplate.convertAndSend(exchangeName, routingKey, messageBody, cd);
                }
            }

            @Override
            public void onFailure(Throwable ex) {
                log.error("处理消息回执失败", ex);
            }
        });
        rabbitTemplate.convertAndSend(exchangeName, routingKey, messageBody, correlationData);
    }
}
```

把这个工具类注册为Bean，注意如果在`spring.factories`配置了自动装配，`@ConditionalOnBean(RabbitTemplate.class)`是要在类上添加的，因为配置了`spring.factories`之后对于所有依赖这个模块的项目都会尝试加载`MQConfig`类型的Bean，而这个类具有对`RabbitTemplate`的`import`，如果依赖这个模块的项目并不需要这个`MQConfig`因此没有`RabbitTemplate`，spring在尝试创建`MQConfig`类型的Bean时就会报`RabbitTemplate`的`ClassNotFoundException`，因此必须在类上假设`@ConditionalOnBean(RabbitTemplate.class)`跳过对`MQConfig`这个Bean的加载

反之，如果没有配置自动装配，而是通过`@Import(MQConfig.class)`导入这个配置类，就不需要在类上添加这个注解，因为`@Import`它的项目一定应该有`RabbitTemplate`

```java
@Configuration
@ConditionalOnBean(RabbitTemplate.class)
public class MQConfig {

    @Bean
    @ConditionalOnBean(RabbitTemplate.class)
    public RabbitMQHelper rabbitMQHelper(RabbitTemplate rabbitTemplate) {
        return new RabbitMQHelper(rabbitTemplate);
    }
}
```

还可以封装一个死信交换机和队列的配置

```java
@Configuration
@ConditionalOnBean(RabbitTemplate.class)
@ConditionalOnProperty(
        prefix = "spring.rabbitmq.listener.simple.retry",
        name = "enabled",
        havingValue = "true"
)
public class MQConsumeErrorAutoConfig {

    @Value("${spring.application.name}")
    private String serverName;

    @Bean
    public DirectExchange errorExchange() {
        return ExchangeBuilder.directExchange("error.direct").build();
    }

    @Bean
    public Queue errorQueue() {
        return QueueBuilder.durable(serverName + ".error.queue").build();
    }

    @Bean
    public Binding errorBinding(Queue errorQueue, DirectExchange errorExchange) {
        return BindingBuilder.bind(errorQueue).to(errorExchange).with(serverName);
    }

    @Bean
    @ConditionalOnBean(RabbitTemplate.class)
    public MessageRecoverer republishMessageRecoverer(RabbitTemplate rabbitTemplate) {
        return new RepublishMessageRecoverer(rabbitTemplate, "error.direct", serverName);
    }
}
```
