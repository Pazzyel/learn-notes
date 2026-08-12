# Redis Best Practice

## 键值设计

### key结构

Redis的Key最好遵循下面的几个约定：

- 遵循基本格式：[业务名称]:[数据名]:[id]
- 长度不超过44字节（>44bytes转换为raw格式不再同一内存位置）
- 不包含特殊字符

### 避免BigKey

一个key-value占用的内存不宜过大，数目不宜过多（对Set，List等类型），否则称为BigKey

以下命令统计每种类型最大的key

    redis-cli -a 密码 --bigkeys

或者使用redis的scan命令扫描所有key

    scan 起始位置 count 数目

返回两个数据，一个是下一个未被扫描的位置，另一个是key列表

删除BigKey

- redis 3.0 及以下版本：如果是集合类型，则遍历BigKey的元素，先逐个删除子元素，最后删除BigKey，否则直接删除这个BigKey
- Redis 4.0以后：- Redis在4.0后提供了异步删除的命令：unlink

### 选择合适的数据结构

储存对象，可以

- 转成JSON字符串用string储存：适用于不需要灵活修改对象字段的情况
- 用hash存储：适用于需要灵活修改对象字段的情况

单个hash的entry数量超过500，redis会用哈希表而不是ziplist存储，内存占用较大

如果hash的field是自增的id，可以拆分成多个hash，将 id / 100 作为key， 将id % 100 作为field，这样每100个元素为一个Hash

## 批处理优化

redis部署在其他机器的情况下，操作redis的延迟大部分是网络传输的延迟，我们可以把多个redis操作合并，一次性传输到redis服务器进行操作

redis提供mest，hmset的批处理命令，例如jedis的mest用一个数组作为参数，arr[j]是key，arr[j + 1]是string类型的value

jedis还提供了pipleline用于提供redis命令的缓冲区

    Jedis jedis = JedisConnectionFactory.getJedis();
    Pipeline pipeline = jedis.pipelined();
    for (int i = 1; i <= 100000; i++) {
        // 放入命令到管道
        pipeline.set("test:key_" + i, "value_" + i);
        if (i % 1000 == 0) {
            // 每放入1000条命令，批量执行
            pipeline.sync();
        }
    }

pipeline也可以进行jedis的命令，只不过是命令先缓存到缓冲区，调用`pipeline.sync()`才会刷新缓冲区，把命令发送到redis服务器

### 集群下的问题

MSET或Pipeline这样的批处理需要在一次请求中携带多条命令，而此时如果Redis是一个集群，那批处理命令的多个key必须落在一个插槽中，否则就会导致执行失败

有三种解决方法

- 串行slot，执行前客户端先计算key的slot，一样slot的key就放到一个组里边，然后对每个组执行pipeline的批处理，串行进行`pipeline.sync()`

- 并行slot，同样按前面的方案分组，但并行执行`pipeline.sync()`

- hash_tag，redis计算key的slot的时候，其实是根据key的有效部分来计算的，通过这种方式就能一次处理所有的key，但如果通过操作key的有效部分，那么就会导致所有的key都落在一个节点上（数据倾斜）

一般推荐使用第二种方法

第一种方法的示例

    //省略配置jedisCluster类
    Map<String, String> map = new HashMap<>();
    //向map添加要保存到redis的数据

    //对Map数据进行分组。根据相同的slot放在一个分组
    //key就是slot，value就是一个组
    Map<Integer, List<Map.Entry<String, String>>> result = map.entrySet()
            .stream()
            .collect(Collectors.groupingBy(
                    entry -> ClusterSlotHashUtil.calculateSlot(entry.getKey()))
            );//根据ClusterSlotHashUtil.calculateSlot(entry.getKey())的返回值分组，key是返回值，value是分组List
    //串行的去执行mset的逻辑
    for (List<Map.Entry<String, String>> list : result.values()) {
        String[] arr = new String[list.size() * 2];
        int j = 0;
        for (int i = 0; i < list.size(); i++) {
            j = i<<2;
            Map.Entry<String, String> e = list.get(0);
            arr[j] = e.getKey();
            arr[j + 1] = e.getValue();
        }
        jedisCluster.mset(arr);
    }

第二种方法可以利用Spring Data Redis提供的`mulitSet()`和`mulitGet()`方法

    Map<String, String> map = new HashMap<>(3);
    //向map添加要保存到redis的数据
    map.put("name", "Rose");
    map.put("age", "21");
    map.put("sex", "Female");
    stringRedisTemplate.opsForValue().multiSet(map);

    List<String> strings = stringRedisTemplate.opsForValue().multiGet(Arrays.asList("name", "age", "sex"));
    strings.forEach(System.out::println);

其原理是使用`RedisFuture<String> mset = super.mset(op)`进行异步消息发送

    @Override
    public RedisFuture<String> mset(Map<K, V> map) {
        //这一步partitioned的key是slot，value是这个slot包含的key
        Map<Integer, List<K>> partitioned = SlotHash.partition(codec, map.keySet());

        if (partitioned.size() < 2) {
            return super.mset(map);
        }
        //要执行的RedisFuture，key是slot，value是这个slot包含的RedisFucture任务
        Map<Integer, RedisFuture<String>> executions = new HashMap<>();

        for (Map.Entry<Integer, List<K>> entry : partitioned.entrySet()) {

            Map<K, V> op = new HashMap<>();//这个slot下的所有key-value对
            entry.getValue().forEach(k -> op.put(k, map.get(k)));//entry的value是map的key

            RedisFuture<String> mset = super.mset(op);//生成RedisFucture任务
            executions.put(entry.getKey(), mset);
        }

        return MultiNodeExecution.firstOfAsync(executions);
    }

## 持久化的配置

持久化需要额外开销

- 用来做缓存的Redis实例尽量不要开启持久化功能
- 建议关闭RDB持久化功能，使用AOF持久化
- 利用脚本定期在slave节点做RDB，实现数据备份
- 设置合理的rewrite阈值，避免频繁的bgrewrite
- 配置no-appendfsync-on-rewrite = yes，禁止在rewrite期间做aof，避免因AOF引起的阻塞
- 部署有关建议：
  - Redis实例的物理机要预留足够内存，应对fork和rewrite
  - 单个Redis实例内存上限不要太大，例如4G或8G。可以加快fork的速度、减少主从同步、数据迁移压力
  - 不要与CPU密集型应用部署在一起
  - 不要与高硬盘负载应用一起部署。例如：数据库、消息队列

## 慢查询优化

在Redis执行时耗时超过某个阈值的命令，称为慢查询。Redis是单线程的，慢查询会大量阻塞其他请求

在redis-cli可以记录慢查询日志，超过阈值的慢查询会记录日志

    config get slowlog-log-slower-than // 获取慢查询阈值，单位是微秒。默认是10000，建议1000
    config set slowlog-log-slower-than 1000 // 设置慢查询阈值
    config get slowlog-max-len // 获取慢查询日志长度，默认是128，建议1000
    config get slowlog-max-len 1000 // 设置慢查询日志长度

用以下命令查看慢查询日志

    slowlog len：查询慢查询日志长度
    slowlog get [n]：读取n条慢查询日志
    slowlog reset：清空慢查询列表

## 安全建议

因为Redis未设置密码，利用了Redis的config set命令动态修改Redis配置，使用了Root账号权限启动Redis等情况可能会把私钥送到服务器造成安全问题，因此有以下建议

- Redis一定要设置密码
- 禁止线上使用下面命令：keys、flushall、flushdb、config set等命令。可以利用rename-command禁用。
- bind：限制网卡，禁止外网网卡访问
- 开启防火墙
- 不要使用Root账户启动Redis
- 尽量不使用默认的端口（6379）

## 内存配置

redis的内存结构一般是

| **内存占用** | **说明**                                                                           |
| -------- | -------------------------------------------------------------------------------- |
| 数据内存     | 是Redis最主要的部分，存储Redis的键值信息。主要问题是BigKey问题、内存碎片问题                                   |
| 进程内存     | Redis主进程本身运⾏肯定需要占⽤内存，如代码、常量池等等；这部分内存⼤约⼏兆，在⼤多数⽣产环境中与Redis数据占⽤的内存相⽐可以忽略。           |
| 缓冲区内存    | 一般包括客户端缓冲区、AOF缓冲区、复制缓冲区等。客户端缓冲区又包括输入缓冲区和输出缓冲区两种。这部分内存占用波动较大，不当使用BigKey，可能导致内存溢出。 |

通过info memory命令查看内存分配的情况，memory stat查看key的主要占用情况

客户端缓冲区：指的就是我们发送命令时，客户端用来缓存命令的一个缓冲区，也就是我们向redis输入数据的输入端缓冲区和redis向客户端返回数据的响应缓存区，输入缓冲区最大1G且不能设置。注要设置的是输出缓冲区

    cilent-output-buffer-limit <class> <hard_limit> <soft limit> <soft seconds>

class是客户端类型，如normal普通，replica主从，pubsub等，hard_limit是硬上限，超过这个上限会增加断开客户端，soft limit + soft seconds是软上限，超过这个上限的给定时间也会断开客户端。默认此项没有大小，处理大量big value可能导致输出过多立刻占满缓冲导致断开连接。因此应该手动设置

## 集群建议

集群有以下问题

- cluster-require-full-coverage no //此项设置为no，否则一个插槽不可用整个集群都停止服务
- 集群间通过ping互相确定状态，节点过多可能大量占用带宽，应该避免大集群，节点数最好少于1000，配置合适的cluster-node-timeout值
- lua和事务都是要保证原子性问题，如果你的key不在一个节点，那么是无法保证lua的执行和事务的特性的，所以在集群模式是没有办法执行lua和事务的

集群存在不少问题，单体的Redis主从节点也可以到达万级别的QPS，如果业务需求不高尽量不使用集群
