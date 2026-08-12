# Redis实战

## Redis入门

### 配置application.yaml

配置application.yaml时，一些需要灵活修改的信息可以单独起一个文件配置，并在application.yaml激活对应环境

    spring:
        profiles:
            active: dev

如上激活了dev环境，此时该环境的配置文件名为application-dev.yaml

### Session登录

调用`getAttribute()`方法获取session对应key的信息，`setAttribute()`设置session对应key的信息

session登录的问题：多台tomcat的session不一致，tomcat集群下用户可能要反复登录

### Redis保存token

Redis的数据信息在集群共享，用用户相关的唯一token为key，用户信息为value（Hash），登录时根据token从Redis获取是否有用户信息进行登录校验

### 补充：JWT

上文介绍的鉴权方法都是依赖服务端存储对应的token等信息，JWT利用密钥和用户信息为每个用户生成唯一的不可篡改的登录令牌，鉴权时能够成功解析令牌就说明JWT令牌有效，还可以从JWT令牌解析出生成令牌时的用户信息，不需要服务端额外存储

JWT也存在一些问题，比如密钥暴露就十分危险，安全性较低，用户修改密码后以前的JWT依然有效等问题，服务端储存token的情况下会更灵活，因此我们依然采用服务端存储token的形式

## Redis缓存 -ShopServiceImpl

用于缓存对应id商铺的信息

### 查询缓存

为了减小数据库压力，加速查询，对查询信息缓存。

和硬件上的缓存类似，查询的策略**是先查询缓存，缓存不命中再查找数据库，并缓存查询的信息**

一开始没有信息加载到缓存，会出现冷不命中，这条数据就被缓存了

### 更新缓存

更新数据库需要同步更新缓存，由于更新了数据时候这条数据不一定会被查询，因此更合理的方案是再更新数据库时只删除缓存，如果有查询，在查询时才重新缓存

更新数据库和删除缓存的先后顺序：**先更新数据库后删除缓存**

先删除缓存后更新数据库：线程1删除了缓存，在更新数据库还未进行时线程2进行查询，缓存不命中查询数据库，并把旧的数据缓存，之后线程1才更新了数据库，发生了缓存和数据库的不一致

先更新数据库后删除缓存：线程1查询一个未缓存数据不命中，查询了数据库，此时线程2更新了数据库，删除了可能的缓存（本情况不存在），之后线程1缓存了旧的数据，发生了缓存和数据库的不一致

由于更新数据库+删除缓存的用时要 > 查询缓存+查询数据库并写入缓存，第二种情况是很少发生的，选择第二种

### 缓存穿透和缓存雪崩

缓存穿透指的是如果查询一个数据库不存在的数据，那么缓存和数据库都不会有对应信息，每次查询都会经过数据库，加大压力
方法：

- **缓存空数据**：在查询数据库发现没有对应信息时，同样也用同样的key缓存这条数据，只是value设置为空
- 布隆过滤：布隆过滤器其实采用的是哈希思想来解决这个问题，通过一个庞大的二进制数组，走哈希思想去判断当前这个要查询的这个数据是否存在，如果布隆过滤器判断存在，则放行，这个请求会去访问redis，哪怕此时redis中的数据过期了，但是数据库中一定存在这个数据，在数据库中查询出来这个数据后，再将其放入到redis中

缓存雪崩指同一时段大量的缓存key同时失效或者Redis服务宕机，导致大量请求到达数据库，带来巨大压力
方法：

- **给不同的Key的TTL添加随机值**
- 利用Redis集群提高服务的可用性
- 给缓存业务添加降级限流策略
- 给业务添加多级缓存

### 缓存击穿

缓存击穿问题也叫热点Key问题，就是一个被高并发访问并且缓存重建业务较复杂的key突然失效了，无数的请求访问会在瞬间给数据库带来巨大的冲击
方法：

- **互斥锁**：对数据库查询过程上锁，只允许一个线程在**缓存不命中**时进行查询数据库+缓存数据的操作，此时其他线程就可以查询到缓存的数据
- **逻辑过期**：利用一个单独的逻辑过期时间字段，如果发现过期就另开一个线程执行带**锁**的重建缓存操作（查询数据库，重新缓存并重设逻辑过期时间），在这个重建缓存的线程完成之前的所有查询线程返回的都是已经逻辑过期的脏数据

互斥锁可以用Redis实现，用SETNX (setIfAbsent方法) 来实现，获取锁就是在Redis插入这个锁的key，成功插入就是获取到锁，已存在就是没获取到锁，释放锁就是移除这个key

逻辑过期的加开线程可以用线程池，加入线程池可以直接用lambda，注意和匿名内部类不同，Lambda表达式的this是外围类的实例，匿名内部类是它自己的实例

## Redis分布式锁

使用Redis的原子操作SETNX实现原子自增，分布式锁等，解决检测库存是否充足，检测是否为同一个用户重复下单，扣减库存，添加订单的原子性问题

### 全局唯一ID -RedisIdWorker

数据量过大可能需要拆表，此时就会出现多个不同数据有一样的id的问题，可以用其他方法生成id，如时间戳+序列号

CountDownLatch是java用于阻塞主线程并等待所有子线程完成的一个工具类，用一个初始值如`new CountDownLatch(300)`初始化，子线程执行完成调用countDown方法减小计数，计数为0时主线程才停止阻塞

### 线程安全问题

比如库存为1时，两个线程都来扣除库存，查询时都发现库存>0都进行了扣除，此时库存就为-1，发生了线程不安全的问题

悲观锁：synchronized，lock等，线程执行操作必须先抢锁，性能开销较大

乐观锁：假设线程安全问题不是经常发生的，线程不抢锁，而是利用一个版本号，每次操作数据会对版本号+1，再提交回数据时，会去校验是否比之前的版本大1 ，如果大1 ，则进行操作成功，这套机制的核心逻辑在于，如果在操作过程中，版本号只比原来大1 ，那么就意味着操作过程中没有人对他进行过修改，他的操作就是安全的，如果不大1，则数据被修改过

乐观锁的另一种典型代表：CAS:判断要更新的变量是否等于之前读取的旧值，如果相等（说明变量没有被更改过，操作安全）才更新内存，如果被更改说明操作不安全，放弃本次更新并重新尝试（自旋）

在更新数据库时在同一条SQL语句中增加判断当前值是否等于旧值可以实现乐观锁的功能

AtomicLong：java提供的计数器原子类，其中的`incrementAndGet()`等方法利用CPU的CAS指令提供原子的自增自减等操作，没有更新成功时自旋

LongAdder：优化大量线程更新时AtomicLong自旋压力大的问题，让多个线程更新不同的cell单元，并延迟合并多个cell使得最后的计数一致

控制锁的粒度：思考应该在什么范围上锁？比如针对一个用户只能下一个单的问题，如果一个用户开了多个线程下单，都发现没有下单造成的线程安全问题。锁的粒度应该是这个用户而不是整个下单方法，我们可以用这个用户的id作为锁，这样锁的范围只针对这个用户的多个线程

如果以用户的id作为锁，直接调用`toString()`方法获取的字符串即使内容相同但内存地址不同，不是同一个对象，无法作为锁，应该对字符串调用`intern()`方法**获取字符串常量池的同一个字符串对象**

### Spring事务和线程锁

Spring事务注解的方法，方法执行完毕后才被Spring进行事务提交，完成数据库的更新

如果当前方法被spring的事务控制，而在方法内部加锁，可能会导致当前方法事务还没有提交，但是锁已经释放，此时新的抢到锁的线程查询的还是没有更新的数据库数据

因此，**如果有事务方法内部需要加锁，锁应当拉取到整个方法的外部进行锁定，保证锁释放时事务已经提交**

### 事务失效

上面介绍的把锁拉取到整个方法的外部，如果我们在同一个类调用事务方法，事务会失效，因为Spring事务是通过AOP的代理类完成的，有事务功能的是代理类的方法而不是原始类的方法，我们直接调用的是原始类的方法

解决方法：引入以下依赖

    <dependency>
        <groupId>org.aspectj</groupId>
        <artifactId>aspectjweaver</artifactId>
    </dependency>

手动获取代理类，在启动类加上`@EnableAspectJAutoProxy(exposeProxy = true)`，可以调用`AopContext.currentProxy()`用于获取该类的代理类，注意，因为Spring的事务是放在ThreadLocal中，**每个线程都必须获取自己的代理类**

### 分布式锁 -VoucherOrderServiceImpl

多个tomcat服务器的所无法实现互斥，Redis集群的数据是共享的，可以用Redis实现分布式锁

误删问题：如果线程1获取锁后发生阻塞，导致线程1的锁超时释放，锁被线程2获取时线程1结束阻塞继续执行，错误释放了线程2的锁

解决：获取锁时加上线程的信息，释放锁时检查是不是自己的线程的锁

获取锁：

    public boolean tryLock(Long timeoutSec) {
        String threadId = ID_PREFIX + Thread.currentThread().getId();
        Boolean res = redisTemplate.opsForValue().setIfAbsent(KEY_PREFIX + name, threadId, timeoutSec, TimeUnit.SECONDS);
        return BooleanUtil.isTrue(res);
    }

释放锁：

    @Override
    public void unlock() {
        String threadId = ID_PREFIX + Thread.currentThread().getId();
        String id = redisTemplate.opsForValue().get(KEY_PREFIX + name);
        // 判断标示是否一致，不一致说明锁已经超时释放，现在的锁不是自己的
        if(threadId.equals(id)) {
            redisTemplate.delete(KEY_PREFIX + name);
        }
    }

### 分布式锁的原子性问题

更为极端的情况：线程1释放锁时判断完当前锁是自己的，但还没执行释放的逻辑，此时锁自己超时释放了，则前面的判断锁是不是自己的没有起到作用

问题的原因：**锁是否存在，是不是自己的的判断逻辑和删除锁的逻辑不是原子性的**

解决：Lua脚本，**Lua可以在一个脚本中编写多条Redis命令，确保多条命令执行时的原子性**
Lua进行Redis调用的格式为`redis.call('命令名称', 'key', '其它参数', ...)`

    -- 这里的 KEYS[1] 就是锁的key，这里的ARGV[1] 就是当前线程标示
    -- 获取锁中的标示，判断是否与当前线程标示一致
    if (redis.call('GET', KEYS[1]) == ARGV[1]) then
        -- 一致，则删除锁
        return redis.call('DEL', KEYS[1])
    end
    -- 不一致，则直接返回
    return 0

Java构造Redis脚本`DefaultRedisScript`的情况，需要指定加载脚本的位置（`steLocation()`方法）和执行脚本的返回类型（`setResultType()`方法），此外指定文件位置也可以使用`setScriptResource()`，这是`steLocation()`的别名，更推荐使用。也可以使用`setScriptText()`，直接传入Java字符串而不需要单独lua文件，内容应该和lua脚本内容一致

    private static final DefaultRedisScript<Long> UNLOCK_SCRIPT;
    static {
        UNLOCK_SCRIPT = new DefaultRedisScript<>();
        UNLOCK_SCRIPT.setLocation(new ClassPathResource("lua/unlock.lua"));
        UNLOCK_SCRIPT.setResultType(Long.class);
    }

这是RedisTemplate用于调用Lua脚本的方法，参数1是脚本内容，参数2是传入脚本的KEYS列表，剩下的参数作为ARGV列表

    public <T> T execute(RedisScript<T> script, List<K> keys, Object... args)

### Redission分布式锁

Redission提供了分布式锁的多种多样的功能

需要通过RedissionClient获取锁，其中host是Redis的地址（`redis://" + "${spring.redis.host}" + ":" + "${spring.redis.port}`），password是连接Redis的密码

    @Bean
    public RedissonClient createRedissonClient() {
        //配置Redisson分布式锁
        Config config = new Config();
        config.useSingleServer().setAddress(host).setPassword(password);
        RedissonClient r = Redisson.create(config);
        return r;
    }

#### Redission的使用

获取锁对象，传入的参数是锁在Redis的key

    RLock lock = redissonClient.getLock("lock:order:" + userId);

获取锁，有两种重载，一种不带参数，另一种有三个参数，分别是获取锁的最大等待时间(期间会重试)，锁自动释放时间，时间单位，两种方法底层有一定区别，在下文介绍

    boolean isLock = lock.tryLock();
    boolean isLock = lock.tryLock(1,10,TimeUnit.SECONDS);
    
#### Redission的原理

Redission在Redis用HASH结构表示锁，Redis的key（以下称为大key）表示锁是否存在，HASH结构的key（以下称为小key）表示这把锁被哪个线程持有

#### Redission如何支持重入

重入：**持有锁的线程重新获取锁进入相同的代码段**

小key对应的value表示当前线程持有锁的次数，重入一次就计数+1

KEYS[1]为大key，ARGV[1]为锁失效时间，ARGV[2]为小key，以下为lua

    -- 不存在锁的情况
    "if (redis.call('exists', KEYS[1]) == 0) then " +
        -- 添加HASH条目
        "redis.call('hset', KEYS[1], ARGV[2], 1); " +
        -- 设置过期时间
        "redis.call('pexpire', KEYS[1], ARGV[1]); " +
        "return nil; " +
    "end; " +
    -- 重入本线程持有的锁
    "if (redis.call('hexists', KEYS[1], ARGV[2]) == 1) then " +
        -- 增加计数
        "redis.call('hincrby', KEYS[1], ARGV[2], 1); " +
        -- 更新过期时间
        "redis.call('pexpire', KEYS[1], ARGV[1]); " +
        "return nil; " +
    "end; " +
    -- 抢锁成功或重入成功都返回null
    -- 抢锁失败
    "return redis.call('pttl', KEYS[1]);"
    -- 抢锁失败返回这个锁的过期时间

#### Redission的自旋抢锁和看门狗机制

如果抢锁的lua返回的不是null，说明抢锁失败，会对获取锁的最大等待时间扣除当前抢锁耗时，并循环自旋抢锁直到最大等待时间耗尽

`tryLock()`有参数时，直接调用如上的lua，简单易懂

`tryLock()`没有传入任何参数时，获取锁的最大等待时间是默认看门狗时间，该时间内没有抢到锁时自旋抢锁。而锁的过期时间则由特殊的看门狗机制管理，可以视为在线程释放锁前无限长

看门狗：看门狗线程被设置为业务线程的守护线程，未传入过期时间时，获取锁后调用`renewExpiration()`方法，注意其中的`commandExecutor.getConnectionManager().newTimeout()`方法，该方法有三个参数，第一个是执行的看门狗线程任务，第二个是续约时间，第三个是续约时间单位。这里续约时间是`internalLockLeaseTime / 3`，也就是在锁的过期时间走到1/3时就递归调用`renewExpiration()`更新过期时间，达到在线程持有锁的期间不过期的目的。当线程释放锁后通知看门狗线程，结束续约。

    Timeout task = commandExecutor.getConnectionManager().newTimeout(new TimerTask() {
        @Override
        public void run(Timeout timeout) throws Exception {
            ExpirationEntry ent = EXPIRATION_RENEWAL_MAP.get(getEntryName());
            if (ent == null) {
                return;
            }
            Long threadId = ent.getFirstThreadId();
            if (threadId == null) {
                return;
            }

            RFuture<Boolean> future = renewExpirationAsync(threadId);
            future.onComplete((res, e) -> {
                if (e != null) {
                    log.error("Can't update lock " + getName() + " expiration", e);
                    return;
                }

                if (res) {
                    // reschedule itself
                    renewExpiration();
                }
            });
        }
    }, internalLockLeaseTime / 3, TimeUnit.MILLISECONDS);

很明显，如果看门狗线程宕机，续约的流程就终止了，锁会自己过期

此外，由于看门狗线程是业务线程的守护线程，如果业务线程因为异常终止了，开门狗线程也会终止，不再续约，包装锁的释放

#### Reddission的MuitLock原理

在Redis主从集群中，可能发生的情况：线程向master节点获取到锁，在slave节点还没同步到锁信息时master宕机，哨兵选择了一个slave节点为master，此时的master不存在锁信息。

使用MutiLock，MutiLock不再依赖Redis的主从，而是对每个Redis节点都要获取锁，总用时为需要获取锁的数量*1500ms，在这个时间内获取到全部的锁才是获取成功，如果没有获取成功，就移除已经获取到锁的节点的锁。

## Redis消息队列 -VoucherOrderServiceImpl --XGROUP

使用消息队列，把下单和订单创建拆分为异步操作，解决下单的速度问题，还方便拆分为微服务

有些业务逻辑可以拆分为**异步执行**，比如抢优惠券中判断是否有资格和创建对应的优惠券订单就是可以拆分的，判断是否有资格后把有资格的放入队列（生产者）就可以马上返回，而另外的线程从队列读取信息创建对应的订单（消费者）

Stream 是 Redis 5.0 引入的一种新数据类型，可以实现一个功能非常完善的消息队列

向消息队列添加消息的格式如下

    XADD key [NOMKSTREAM] [MAXLEN|MINID [=|~] threshold [LIMIT count]] *|ID field value [field value ...]

- key是消息队列名称
- NOMKSTREAM存在时不自动创建消息队列
- MAXLEN|MINID [=|~] threshold [LIMIT count] 消息队列的最大消息数量
- *|ID是消息的唯一ID，*标识由Redis自动生成，格式为时间戳-递增数字
- field value [field value ...] 发送到队列的消息，为一个或多个key-value键值对

消费者组：将多个消费者划分到一个组中，监听同一个队列，消费者组会维护最后一个处理的消息的标识，即使消费者宕机重启也会从下一个未被处理的消息开始读取，防止漏读。创建消费者组的格式如下，带[]的是可选参数

    XGROUP CREATE key groupName ID [MKSTREAM]

- key是消息队列名称
- groupName是消费者组名称
- ID是起始ID标识，0为第一个消息，$为最后一个消息
- MKSTREAM：队列不存在时自动创建队列

消费者读取一个消息，消息处于pending状态，存入pending-list，通过XACK确认信息将消息标记为已处理，才会从pending-list移除

从消费者组读取消息格式如下，带[]的是可选参数

    XREADGROUP GROUP group consumer [COUNT count] [BLOCK milliseconds] [NOACK] STREAMS key [key ...] ID [ID ...]

- group：消费组名称
- consumer：消费者名称，如果消费者不存在，会自动创建一个消费者
- count：本次查询的最大数量
- BLOCK milliseconds：当没有消息时最长等待时间
- NOACK：无需手动ACK，获取到消息后自动确认
- STREAMS key：指定队列名称
- ID：获取消息的起始ID，如果是>说明从下一个未消费的消息开始，防止漏读

Java调用

    XREADGROUP GROUP g1 c1 COUNT 1 BLOCK 2000 STREAMS s1 > 

    //相当于以下Java调用
    List<MapRecord<String, Object, Object>> list = stringRedisTemplate.opsForStream().read(
        Consumer.from("g1", "c1"),
        StreamReadOptions.empty().count(1).block(Duration.ofSeconds(2)),
        StreamOffset.create("stream.orders", ReadOffset.lastConsumed())
    );

    //调用以下获取实际的Map的key-value
    MapRecord<String, Object, Object> record = list.get(0);
    Map<Object, Object> map = record.getValue();
    //这里的结果就是消费者存入的key-value列表

## Redis有序集合 -BlogServiceImpl

解决根据时间查询点赞最早的用户的问题

SortedSet是Redis提供的一个有序集合，在Reids内根据score的值降序排序，当我们需要有序数据结构时可以使用

Spring Data Redis 提供`score()`方法获取集合某个条目的score，参数1是Redis的大key，参数2是SortedSet里的项，返回这个项的score值

    Double score = stringRedisTemplate.opsForZSet().score(key, userIdString);

Spring Data Redis 提供`range()`方法获取集合某个条目的score，参数1是Redis的大key，参数2是起始范围，参数3是结束范围，索引从0开始，是闭区间，返回对应范围的SortedSet里的项集合

    Set<String> top5 = stringRedisTemplate.opsForZSet().range(key, 0, 4);//点赞最早5个人的id

### SQL按照指定的顺序排序

可以用`ORDER BY FIELD (field, item1, item2,...)`指定排序的顺序，field是数据库里根据这一项排序的字段，item1, item2,... 是要排成的顺序

把列表的结果参照field字段的 tem1, item2,... 顺序排序， 如果 item1, item2,... 不包含这个数据的内容，这条数据会被排在在最前面

Spring Data Redis 提供`in()`方法执行SQL的`IN`（只需传入集合），还提供`last()`方法将指定的SQL语句拼接到最后

    List<Long> ids = top5.stream().map(Long::parseLong).collect(Collectors.toList());
    String idStr = StrUtil.join(",",ids);//在原来的每个id之间插入逗号
    List<User> users = userService.query().in("id",ids).last("ORDER BY FIELD (id," + idStr + ")").list();

## Feed流推送 -BlogServiceImpl

用rangeByScore()解决倒序过程分页查询有新的数据加入导致顺序混乱的问题，手动指定唯一id（score）

系统将内容推送给用户而不是用户寻找内容

Timeline模式：不做内容筛选，简单的按照内容发布时间排序

- 拉模式（读扩散）：用户客户端读取信息时才请求服务端，缺点：如果用户需要请求大量信息，服务端压力大
- 推模式（写扩散）：用户发布消息时就直接推送到需要推送的客户端，缺点：如果消息需要推送到多个客户端，服务端压力大
- 推拉结合：例如博客，针对普通用户，粉丝少，需要推送的客户端少，发布消息时采用推模式，针对热门用户，粉丝量大，只对核心粉丝采用推模式，其他粉丝采用拉模式

### Feed流的分页问题

传统的分页方式利用page和pageSize完成，但在Feed流中，用户新发送一条消息到最前面，其他消息的顺序就改变了，此时再用page和pageSize会读到旧的一条消息

解决方法：维护每次读到的位置，下次分页从这个位置读取

可以用SortedSet来实现，我们把消息id插入集合，消息的时间戳作为score，只需要记录每次分页查询最后一条消息的score即可

Spring Data Redis 提供了`rangeByScore()`方法来根据score的范围查询，参数为`(K key, double min, double max, long offset, long count)`

`key`是Redis的大key，`min`是score的最小值，`max`是score的最大值，`offset`是要跳过的记录偏移量，`count`是要查询记录的数目，注意范围是闭区间，也就是[min,max]

reserve表示逆序查询（默认按照score升序），withScores表示查询的结果会含有score的值，注意就算是逆序min，max也是一样的

    Set<ZSetOperations.TypedTuple<String>> typedTuples = stringRedisTemplate.opsForZSet()
                .reverseRangeByScoreWithScores(key, 0, max, offset, 2);//每次查询2条数据，注意reverse，降序查询

`ZSetOperations.TypedTuple<>`是withScores后查询返回的结果，其有`getValue()`方法用于获取值（泛型是值的类型）和`getScore()`方法用于获取score（Double类型）

查询完成后，我们只需要记录最小的时间戳（下次的max）和时间是最小时间戳的数据数目（下次的offset）即可

### 补充：WebSocket

Http协议的请求-响应模式需要用户请求才能向服务端发送消息，WebSocket协议下建立连接后服务端就可以**主动向客户端推送消息**

以下用于注册WebSocket接入点bean

    @Configuration
    public class WebSocketConfiguration {
        @Bean
        public ServerEndpointExporter serverEndpointExporter() {
            return new ServerEndpointExporter();
        }
    }

以下是WebSocket服务的一些方法

    @Component
    @ServerEndpoint("/ws/{sid}")//WebSocket接入地址
    public class WebSocketServer {

        private static Map<String, Session> sessionMap = new HashMap<>();

        //@OnOpen说明这个是建立WebSocket连接的方法，session是连接的session
        @OnOpen
        public void onOpen(Session session, @PathParam("sid") String sid) {
            System.out.println("收到来自客户端的连接: " + sid);
            sessionMap.put(sid, session);
        }

        //收到客户端消息后调用的方法
        @OnMessage
        public void onMessage(String message, @PathParam("sid") String sid) {
            System.out.println("收到来自客户端: " + sid + "的消息: " + message);
        }

        //连接关闭调用的方法
        @OnClose
        public void onClose(@PathParam("sid") String sid) {
            System.out.println("连接断开: " + sid);
            sessionMap.remove(sid);
        }

        //服务端可以主动向客户端发送消息
        public void sendToAllClients(String message) {
            Collection<Session> sessions = sessionMap.values();
            for (Session session : sessions) {
                try {
                    session.getBasicRemote().sendText(message);
                } catch (Exception e) {
                    e.printStackTrace();
                }
            }
        }
    }

## GEO数据结构

GEO是Redis用于储存地理坐标信息的数据结构

`RedisGeoCommands.GeoLocation<>`是Spring Data Redis提供的Geo项的类，泛型是储存的name的类型

调用`RedisGeoCommands.GeoLocation(T name, Point point)`进行构造，`Point`是坐标类，调用`Point(double x, double y)`构造

该类提供`getName()`方法用于获取name

进行Geo查询的例子，Distance单位默认为米

    GeoResults<RedisGeoCommands.GeoLocation<String>> search = stringRedisTemplate.opsForGeo().search(
        key,//参数 1：Redis 中的 key
        GeoReference.fromCoordinate(x, y),// 参数 2：搜索参考点（经纬度）
        new Distance(5000),// 参数 3：搜索范围（单位默认为米）
        RedisGeoCommands.GeoSearchCommandArgs.newGeoSearchArgs().includeDistance().limit(end)// 参数 4：搜索附加参数（包含与参考点的位置信息，最多搜索end条数据）
    );

其中的search方法：key是Redis的大key，reference是参考点，raidus是半径，args是搜索的其他参数

    GeoResults<RedisGeoCommands.GeoLocation<M>> search(K key, GeoReference<M> reference, Distance radius, RedisGeoCommands.GeoSearchCommandArgs args)

GeoResults<>是search方法返回的类型，调用其`getContent()`可以获取列表类型`List<GeoResult<RedisGeoCommands.GeoLocation<>>>`

`GeoResult<RedisGeoCommands.GeoLocation<>>`是封装的单条返回结果，使用`getContent()`方法可以获取查询到的原始的`RedisGeoCommands.GeoLocation<>`类，`getDistance()`方法可以获得带有距离消息的`Distance`类，对`Distance`类调用`getValue()`获取距离的值（Double类型）

    List<Long> ids = new ArrayList<>();
    Map<Long,Double> distanceMap = new HashMap<>();
    content.stream().forEach(r -> {
        //这里的r是GeoResult，调用getContent()后才是GeoLocation,也就是Spring里储存Redis的Geo单元信息的类
        String idStr = r.getContent().getName();//获取单元的名称
        Long id = Long.parseLong(idStr);
        ids.add(id);
        distanceMap.put(id,r.getDistance().getValue());
    });

Geo结构其实是利用SortedSet存储的，用value储存name，用score储存地理位置

## BitMap的使用

位图（BitMap）是一种表示二进制位信息的结构，适合存储只有是或者否但是数据量大的数据，如签到信息

在Redis中，BitMap是用String储存的，最大上限是512M，即2^32个bit位，在Spring Data Redis中，BitMap的相关操作是封装在字符串操作里的

`getBit()`方法用于获取指定偏移量的0/1状态

    Boolean getBit(K key, long offset);

`setBit()`方法用于设置指定偏移量的0/1状态

    Boolean setBit(K key, long offset, boolean value);

`bitField()`方法用于获取一整个区域的BitMap信息，按顺序储存在多个Long中，key是Redis大key，subCommands是查询的条件

    List<Long> bitField(K key, BitFieldSubCommands subCommands);

subCommands的使用如下

    int day = ...;
    List<Long> bitMaps = stringRedisTemplate.opsForValue().bitField(key,
                BitFieldSubCommands.create().get(BitFieldSubCommands.BitFieldType.unsigned(day)).valueAt(0));
    //get(...) 表示要从 Redis 中 读取 bit 值。
    //BitFieldType.unsigned(day)：表示要以 无符号整数 的方式读取，长度是 day 个 bit。
    //valueAt(0)：从 bit 偏移量 0 开始读（即从第 0 位开始）

### 补充：利用BitMap解决缓存穿透

前文提到可以Reids缓存空数据来解决缓存穿透，事实上还可以提前把存在的数据的id写入Reids的集合中，查询时直接先查询集合，没有这个id说明会穿透，直接返回数据

但数据量大的时候集合占用的内存也很大，可以用BitMap减少内存开销

利用哈希算法计算把id映射到BitMap的位置，把这个位置设置位1，用户查询时用同样的哈希算法算出位置，获取这个位置的位

## HyperLogLog

统计访问量可以通过记录每个访客的id到Redis集合中，访问量就是集合的总数

访问量很大时，集合也会很大，事实上统计访问量上我们并不关心是谁访问了，也就是不关心集合的内容，只关心集合的基数

Hyperloglog(HLL)是从Loglog算法派生的概率算法，用于确定非常大的集合的基数，而不需要存储其所有值，Redis的HLL基于String实现

Hyperloglog(HLL)其测量结果是概率性的，有小于0.81％的误差

`add(K key, V... values)`向HLL添加一条数据，`size(K key)`求集合基数

    @Test
    public void testHyperLogLog(){
        //测试HLL算法统计UV次数（User Visit用户访问量），百万数据量
        String[] users = new String[1000];//模拟1000个用户
        int index = 0;
        for (int i = 1; i <= 1000000; i++) {
            users[index++] = "user_" + i;
            if(i % 1000 == 0){
                //每1000次提交整组用户
                index = 0;
                stringRedisTemplate.opsForHyperLogLog().add("hll1",users);
            }
        }
        Long size = stringRedisTemplate.opsForHyperLogLog().size("hll1");
        System.out.println("size=" + size);
    }

某一次测试的结果是size=997593，误差在允许范围内
