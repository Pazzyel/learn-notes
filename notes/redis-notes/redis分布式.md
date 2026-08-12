# Redis分布式缓存

## Reids持久化

### RDB持久化

RDB持久化是把内存中的所有数据都记录到磁盘中，保存为RDB文件（全称Redis Database Backup file）（Redis数据备份文件）

以下情况触发RDB持久化

- 执行save命令，由Redis主进程执行RDB，会阻塞其他所有命令
- 执行bgsave命令，开启子进程执行RDB
- Redis停机时，Redis会执行一次save命令
- 触发RDB条件时，在在redis.conf配置

RDB触发的条件配置项

    # 900秒内，如果至少有1个key被修改，则执行bgsave ， 如果是save "" 则表示禁用RDB
    save 900 1  
    save 300 10  
    save 60 10000

RDB的其他配置项

    # 是否压缩 ,建议不开启，压缩也会消耗cpu，磁盘的话不值钱
    rdbcompression yes

    # RDB文件名称
    dbfilename dump.rdb  

    # 文件保存的路径目录
    dir ./ 

#### RDB原理

执行bgsave会fork一个子进程用于执行RDB，此时主进程和子进程共享数据的内存，主进程写入时采用写时赋值技术，copy一份副本进行写入避免影响RDB

### AOF持久化

AOF全称为Append Only File（追加文件）。Redis处理的每一个写命令都会记录在AOF文件，可以看做是命令日志文件，通过记录命令而不是记录数据的方式进行持久化

    # 是否开启AOF功能，默认是no
    appendonly yes
    # AOF文件的名称
    appendfilename "appendonly.aof"

AOF的命令记录的频率配置项

    # 表示每执行一次写命令，立即记录到AOF文件
    appendfsync always 
    # 写命令执行完先放入AOF缓冲区，然后表示每隔1秒将缓冲区数据写到AOF文件，是默认方案
    appendfsync everysec 
    # 写命令执行完先放入AOF缓冲区，由操作系统决定何时将缓冲区内容写回磁盘
    appendfsync no

执行bgrewriteaof命令可以进行AOF文件重写，清除结果会被覆盖的无效命令，redis.conf中提供了触发重写阈值的配置项

    properties
    # AOF文件比上次文件 增长超过多少百分比则触发重写
    auto-aof-rewrite-percentage 100
    # AOF文件体积最小多大以上才触发重写 
    auto-aof-rewrite-min-size 64mb 

## Redis主从集群（Replication）

Redis主从集群的情况下，slave节点只能执行读操作

可以通过命令配置主从，重启后会失效

在子节点的客户端执行以下命令

    # SLAVEOF host port
    SLAVEOF 127.0.0.1 6379

如果主节点需要密码，需要提前配置

    CONFIG SET masterauth xxxxxx(主节点密码)

也可以在redis.conf配置，永久生效

    masterauth xxxxxx(主节点密码)
    slaveof(或replicaof) 127.0.0.1 6379

通过`info replication`查看主从状态

### 全量同步

当slave节点第一次连接到master节点时，需要同步master节点的全部数据，称为全量同步

- **Replication Id**（repid）是数据集的标记，标记一致是同一个数据集，slave节点第一次连接标记不一致，master节点才会知道要进行全量同步
- **offset**：偏移量，当前数据的偏移量，全量同步也会同步偏移量，slave节点的offset落后master说明数据需要更新

全量同步流程是

1. slave发送同步请求，repid不一致，master节点进行全量同步，先发送repid和offset
2. master进行RDB，并在RDB的过程记录repl_baklog（RDB过程的命令，类似AOF），RDB完成后把RDB文件发送给slave，slave加载RDB的数据
3. master把RDB过程的repl_baklog的命令一起发送给slave，slave更新自己的数据

### 增量同步

slave节点的offset落后master，数据需要更新时进行增量同步

master会将repl_baklog中master的offset和slave的offset之间的命令发送给slave进行同步

repl_baklog记录Redis处理过的**命令日志**及offset，是一个环形数组，**角标到达数组末尾后，会再次从0开始读写**，覆盖之前的命令和offset

如果slave长时间未同步，slave对应的offset在master的repl_baklog被覆盖，就无法增量同步，只能全量同步

## Redis哨兵（Sentinel）

哨兵用于监测集群的状态，配置如下

    port 27001 # Sentinel的端口
    sentinel announce-ip 192.168.150.101 # Sentinel在向外通告自己时，使用的IP地址，一般用在多网卡环境等，填宿主机的可访问 IP
    sentinel monitor <mymaster> <192.168.150.101> <7001> <2> # Sentinel监听的master地址，mymaster是给master定义的名称，2是选举master时的quorum值
    sentinel down-after-milliseconds <mymaster> <5000> # 主观下线时间
    sentinel failover-timeout <mymaster> <60000> # 故障转移最大耗时
    dir "/tmp/s1"

在Spring Data Redis中，在application.yaml配置如下连接哨兵

    spring:
    redis:
        sentinel:
        master: mymaster -- 给master定义的名称
        nodes: -- 几个哨兵的地址
            - 192.168.150.101:27001
            - 192.168.150.101:27002
            - 192.168.150.101:27003

有了哨兵可以方便的配置读写分类，需要添加以下bean

    @Bean
    public LettuceClientConfigurationBuilderCustomizer clientConfigurationBuilderCustomizer(){
        return clientConfigurationBuilder -> clientConfigurationBuilder.readFrom(ReadFrom.REPLICA_PREFERRED);
    }

其实有四种策略，分别是

- MASTER：从主节点读取
- MASTER_PREFERRED：优先从master节点读取，master不可用才读取replica
- REPLICA：从slave（replica）节点读取
- **REPLICA _PREFERRED**：优先从slave（replica）节点读取，所有的slave都不可用才读取master

哨兵有如下作用

- **监控**：Sentinel 会不断检查您的master和slave是否按预期工作
- **自动故障恢复**：如果master故障，Sentinel会将一个slave提升为master。当故障实例恢复后也以新的master为主
- **通知**：Sentinel充当Redis客户端的服务发现来源，当集群发生故障转移时，会将最新信息推送给Redis的客户端

Sentinel每隔1秒向集群的每个Redis实例发送ping命令，监测服务状态（**监控**）

- 主观下线：某sentinel节点发现某实例未在规定时间响应
- 客观下线：超过指定数量（quorum）的sentinel都认为该实例主观下线

master客观下线，sentinel会在salve中选择一个作为新的master，优先级是：断开时间（超过指定值（down-after-milliseconds * 10）则会排除），slave-priority值（越小越优先，排除0），offset值（越新越优先），slave节点的运行id（越小越优先）

流程是

1. 向选定slave发送slaveof no one命令，让该节点成为master（**故障恢复**）
2. 给所有其它slave发送slaveof <new_host> <new_port> 命令，让这些slave成为新master的从节点,同步数据（**通知**）
3. 将故障节点标记为slave，故障节点恢复后变为slave

## Redis分片集群（Cluster）

分片集群是多个主从集群构成的集群，master之间通过ping监测彼此健康状态

Redis5.0后，可以用以下命令创建集群

    redis-cli --cluster create --cluster-replicas 1 192.168.150.101:7001 192.168.150.101:7002 192.168.150.101:7003 192.168.150.101:8001 192.168.150.101:8002 192.168.150.101:8003

命令说明：

- `redis-cli --cluster`或者`./redis-trib.rb`：代表集群操作命令
- `create`：代表是创建集群
- `--replicas 1`或者`--cluster-replicas 1` ：指定集群中每个master的slave个数为1，此时`节点总数 ÷ (replicas + 1)` 得到的就是master的数量。因此节点列表中的前n个就是master，其它节点都是slave节点，随机分配到不同master

查看集群状态`redis-cli -p <port> cluster nodes`

连接到集群需要加上`-c`参数，`redis-cli -c -p 7001`

在Spring Data Redis中，在application.yaml配置如下连接分片集群，需要配置所有slave和master

    spring:
        redis:
            cluster:
                nodes:
                    - 192.168.150.101:7001
                    - 192.168.150.101:7002
                    - 192.168.150.101:7003
                    - 192.168.150.101:8001
                    - 192.168.150.101:8002
                    - 192.168.150.101:8003

同样通过哨兵的方法配置读写分离

### 插槽

Redis会把每一个master节点映射到0~16383共16384个插槽，创建集群时平分给每个master

数据key与插槽绑定,redis会根据key的有效部分hash计算插槽值（如果有{}且{}内不为空{}内的是有效部分，否则全是）

添加新节点`redis-cli --cluster add-node  <新的host:port> <其中一个master的host:port>`，新加入的默认为master，且没有任何插槽

运行`redis-cli --cluster reshared <需要分享插槽的主节点的host:port>`可以把一个master的插槽分享给其他master，过程中需要指定数目和目标master的ID（在加入集群时可以获取到）

### 故障转移

其中一个master宕机，集群会提升一个slave为master，原master恢复后成为slave

对一个slave执行`cluster failover`可以手动让某个master的地位转移给这个slave
