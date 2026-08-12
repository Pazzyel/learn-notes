# Redis原理

## Redis底层数据结构

### 字符串：SDS

Redis构建了一种新的字符串结构，称为简单动态字符串（Simple Dynamic String），简称SDS

底层是一个sdshdr8的C结构体，包括len（uint8_t），alloc（uint8_t），flags（unsigned char，用于分辨类型），buf（char[]数组，实际数据）

假如我们要给SDS追加一段字符串，如果这导致len > alloc，这里首先会申请新内存空间，再把内容写入新空间

如果新字符串小于1M，则新空间为扩展后字符串长度的两倍+1；

如果新字符串大于1M，则新空间为扩展后字符串长度+1M+1。称为内存预分配

### 集合：InSet

底层是一个inset的C结构体，包括encoding（uint32_t，表示有效载荷的编码方式，有16，32，64位整数），length（uint32_t），contents（int8_t[]，有效载荷）

contents数据不会重复，且是按升序储存的，因此能通过二分来把单个和区间查找优化到O(logn)

encoding是自动的匹配的，匹配能包含当前集合的元素的最小类型，当插入新元素时重新编码，扩大数组并倒序的把元素搬到新位置

插入新元素先扩大数组+1，再二分查找插入位置，把后面所有元素向后移一位再插入，因此是O(n)的

### 键值对：Dict

Dict由3种C结构体配合形成，分别是dict，dictht，dictEntry，类似HashMap

![1653985824540](.\原理篇.assets\1653985824540.png)

dict是最外层的类型，包括type（dictType*，用于储存哈希函数）privdata（void*，用于特殊hash运算），ht（dictht[]，长度为2，0位置是实际的dictht，1位置是一个空dictht，用于rehash）rehashidx(用于rehash，没有rehash时为-1)，pauserehash（rehash是否暂停）

dictht是哈希表的类型，包括table（dictEntry*[]，哈希表载荷），size（总数组大小，一定是2^n），sizemash（= size - 1），used（unsigned long，实际使用的哈希桶数量）

dictEntry是哈希桶类型，包括key（void*），v（8字节的union，值），next（struct dictEntry*，下一个冲突的桶），Dict在哈希冲突时使用链表，和HashMap不同的是没有转化成红黑树的机制

Dict有两种负载因子，超过执行扩容，计算方法是LoadFactor = used / size，

- 哈希表的 LoadFactor >= 1，并且服务器没有执行 BGSAVE 或者 BGREWRITEAOF 等后台进程
- 哈希表的 LoadFactor > 5

扩容和HashMap一样，扩容后的长度一定是第一个能够容纳所需长度的2^n，初始的size = 4，新的sizemask和key做&运算可以获得新的位置

扩容后进行rehash，rehash是在ht[1]上分配内存并把ht[0]的位置上的元素一个个映射到新位置，最后才释放ht[0]的内存并把ht[0]指向rehash后的dictht，这样的设计在rehash过程中，新增操作，则直接写入ht[1]，查询、修改和删除则会在dict.ht[0]和dict.ht[1]依次查找并执行

rehash过程采用的是渐进式rehash，也就是一次只执行一个元素的rehash操作，在rehash过程中设置rehashidx = 0，每次对Dict的操作都会把rehashidx上对应的key-value结构搬到ht[1]，并增加rehashidx 1，直到rehashidx达到ht[0]的末尾，此时ht[0]指向ht[1]，ht[1]指向null

和HashMap不一样的是Dict提供了缩小的机制，LoadFactor <>= 0.1触发缩小，size最小只能缩小到4

### 压缩链表：ZipList

压缩链表不像LinkedList链表，因为它的内存地址是连续的

![1653985987327](.\原理篇.assets\1653985987327.png)

按顺序包括zlbytes（uint32_t，总字节数），zltail（uint32_t，尾偏移量，是结尾地址同起始地址的差值），zllen（uint16_t，entry个数），一系列entry节点，zlend（uint8_t，值为0xff的尾部标记）

entry的结构包括

- previous_entry_length：前一节点的长度，占1个或5个字节，用于寻址上一个节点的位置
  
  - 如果前一节点的长度小于254字节，则采用1个字节来保存这个长度值
  - 如果前一节点的长度大于254字节，则采用5个字节来保存这个长度值，第一个字节为0xfe，后四个字节才是真实长度数据
- encoding：编码属性，记录content的数据类型（字符串还是整数）以及长度，占用1个、2个或5个字节
- contents：负责保存节点的数据，可以是字符串或整数

encoding有字符串和整数两种编码

字符串：如果encoding是以“00”、“01”或者“10”开头，则证明content是字符串

| **编码** | **编码长度** | **字符串大小** |
| --- | --- | --- |
| \\|00pppppp\\| | 1 bytes | <= 63 bytes |
| \\|01pppppp\\|qqqqqqqq\\| | 2 bytes | <= 16383 bytes |
| \\|10000000\\|qqqqqqqq\\|rrrrrrrr\\|ssssssss\\|tttttttt\\| | 5 bytes | <= 4294967295 bytes |

- 整数：如果encoding是以“11”开始，则证明content是整数，且encoding固定只占用1个字节

| **编码** | **编码长度** | **整数类型** |
| --- | --- | --- |
| 11000000 | 1   | int16_t（2 bytes） |
| 11010000 | 1   | int32_t（4 bytes） |
| 11100000 | 1   | int64_t（8 bytes） |
| 11110000 | 1   | 24位有符整数(3 bytes) |
| 11111110 | 1   | 8位有符整数(1 bytes) |
| 1111xxxx | 1   | 直接在xxxx位置保存数值，范围从0001~1101，减1后结果为实际值 |

如过有多个连续长度接近但小于254字节的节点，突然在前面插入一个大节点使得后面的节点需要用5字节表示时又引发其长度大于254字节，这一串节点会连锁更新为5字节的previous_entry_length

### 优化压缩链表：QuickList

单纯的ZipList需要连续内存，分配连续的大内存是有挑战性的

![1653986718554](.\原理篇.assets\1653986718554.png)

QuickList是一个真正的双端链表，只不过每个链表quickListNode都指向一个ZipList

QuickList限制每个ZipList的大小，Redis提供了一个配置项：list-max-ziplist-size来限制。
如果值为正，则代表ZipList的允许的entry个数的最大值
如果值为负，则代表ZipList的最大内存大小，分5种情况，默认-2

- -1：每个ZipList的内存占用不能超过4kb
- -2：每个ZipList的内存占用不能超过8kb
- -3：每个ZipList的内存占用不能超过16kb
- -4：每个ZipList的内存占用不能超过32kb
- -5：每个ZipList的内存占用不能超过64kb

quickList结构体储存quickListNode的头尾节点的指针，count（总ziplist的entry数量），len（quickListNode链表长度），fill（就是上文的ziplist限制）

quickListNode包括prev，next指针，和zl指针指向实际zipList

### 跳表：ZSkipList

跳表是一个类似B+树的结构，数据按升序排序并用链表存储（最下层的链表跨度是1），和B+树不同的是其上层也是链表，但跨度一定比下一层大，跨度大的层用于快速遍历到指定位置，上层链表还储存下次同样数据节点的指针用于访问下层，层可以很多，但上层的跨度一定比下一层大

![1653986877620](.\原理篇.assets\1653986877620.png)

zskiplist包括叶子节点的头尾指针，len（长度），level（层数等级）

zskiplistNode包括ele值，backward（上一个节点指针），score（用于排序），level（zskipLevel数组，对一个叶子节点，其上可能有0-多个上层节点，level数组储存这个叶子节点位置全部的节点），下一个节点的指针在zskipLevel结构定义

zskipLevel包括forward（下一个节点指针），span（跨度），在这里定义下一个节点的指针是因为不同层的下一个节点不同

### 类型抽象：RedisObject

Redis的key是SDS字符串，但value可能是多种类型，RedisObject是对多种value类型的抽象

redisObject包括type（unsigned，value类型，是直接对外提供的类型，不是底层类型），encoding（unsigned，编码方式，一般编码成上面介绍的一种底层类型），lru（记录该object最后一次访问的时间，用于实现LRU），refcount（int，引用计数，用于垃圾回收），ptr（void*，实际数据内存指针）

encoding的编码有这几种

| **编号** | **编码方式**                | **说明**        |
| ------ | ----------------------- | ------------- |
| 0      | OBJ_ENCODING_RAW        | raw编码动态字符串    |
| 1      | OBJ_ENCODING_INT        | long类型的整数的字符串 |
| 2      | OBJ_ENCODING_HT         | hash表（字典dict） |
| 3      | OBJ_ENCODING_ZIPMAP     | 已废弃           |
| 4      | OBJ_ENCODING_LINKEDLIST | 双端链表          |
| 5      | OBJ_ENCODING_ZIPLIST    | 压缩列表          |
| 6      | OBJ_ENCODING_INTSET     | 整数集合          |
| 7      | OBJ_ENCODING_SKIPLIST   | 跳表            |
| 8      | OBJ_ENCODING_EMBSTR     | embstr的动态字符串  |
| 9      | OBJ_ENCODING_QUICKLIST  | 快速列表          |
| 10     | OBJ_ENCODING_STREAM     | Stream流       |

各种value类型能选择的编码方式

| **数据类型**   | **编码方式**                                   |
| ---------- | ------------------------------------------ |
| OBJ_STRING | int、embstr、raw                             |
| OBJ_LIST   | LinkedList和ZipList(3.2以前)、QuickList（3.2以后） |
| OBJ_SET    | intset、HT                                  |
| OBJ_ZSET   | ZipList、HT、SkipList                        |
| OBJ_HASH   | ZipList、HT                                 |

## Redis数据结构

所有直接提供使用的Redis数据结构的value都是RedisObject，因此都有redisObject结构体的头，实际数据则在ptr指向的位置，ptr指向一种底层Redis数据结构

### String

String的type是OBJ_STRING，encoding有三种形式

- OBJ_ENCODING_INT，当存储的字符串是整数值，并且大小在LONG_MAX范围内，ptr不再是指针，而是表示一个64位整数
- OBJ_ENCODING_RAW，ptr指向一个SDS字符串
- OBJ_ENCODING_EMBSTR，ptr指向一个SDS字符串，但SDS字符串和redisObject头的内存地址是连续的

incr, decr命令是用于操作整数形式编码的，如果实际是字符串会先尝试转化成整数

对⼀个内部表示成int型的string执行append, setbit, getrange这些命令（它们默认是用于字符串的），int会先转化成SDS字符串的形式

### List

Redis的List结构类似一个双端链表，可以从首、尾操作列表中的元素：

在3.2版本之前，Redis采用ZipList和LinkedList来实现List，当元素数量小于512并且元素大小小于64字节时采用ZipList编码，超过则采用LinkedList编码。

在3.2版本之后，Redis统一采用QuickList来实现List，RedisObject头结构的ptr指向QuickList结构体

### Set

Set是Redis中的集合，不一定确保元素有序，可以满足元素唯一、查询效率要求极高

为了查询效率和唯一性，set采用HT编码（Dict）。Dict中的key用来存储元素，value统一为null

当存储的所有数据都是整数，并且元素数量不超过set-max-intset-entries时，Set会采用IntSet编码，以节省内存

### ZSet

ZSet共同使用Dict和SkipList来存储，dict指针指向Dict结构，它是无序的但查找效率O(1)，因此用于查找，zsl指针指向跳表，它的链表是按照score排序的，可以用于范围查找

当元素数量不多时，HT和SkipList的优势不明显，而且更耗内存。因此zset还会采用ZipList结构来节省内存，不过需要同时满足两个条件：

- 元素数量小于zset_max_ziplist_entries，默认值128
- 每个元素都小于zset_max_ziplist_value字节，默认值64

ziplist本身没有排序功能，而且没有键值对的概念，因此需要有zset通过编码实现：

- ZipList是连续内存，因此score和element是紧挨在一起的两个entry， element在前，score在后
- score越小越接近队首，score越大越接近队尾，按照score值升序排列

### Hash

Hash结构默认采用ZipList编码，用以节省内存。 ZipList中相邻的两个entry 分别保存field和value，因此查找是O(n)的，但数据量很小因此影响不大

当数据量较大时，Hash结构会转为HT编码，也就是Dict，查找变为O(1)，触发条件有两个：

- ZipList中的元素数量超过了hash-max-ziplist-entries（默认512）
- ZipList中的任意entry大小超过了hash-max-ziplist-value（默认64字节）

## Redis网络模型

一般情况下Redis的核心操作命令执行是单线程的

在Redis版本迭代过程中，在两个重要的时间节点上引入了多线程的支持：

- Redis v4.0：引入多线程异步处理一些耗时较旧的任务，例如异步删除命令unlink
- Redis v6.0：在核心网络模型中引入 多线程，进一步提高对于多核CPU的利用率

因此，对于Redis的核心网络模型，在Redis 6.0之前确实都是单线程。是利用epoll（Linux系统）这样的IO多路复用技术在事件循环中不断处理客户端情况。

Redis选择单线程的原因

- 抛开持久化不谈，Redis是纯 内存操作，执行速度非常快，它的性能瓶颈是网络延迟而不是执行速度，因此多线程并不会带来巨大的性能提升。
- 多线程会导致过多的上下文切换，带来不必要的开销
- 引入多线程会面临线程安全问题，必然要引入线程锁这样的安全手段，实现复杂度增高，而且性能也会大打折扣

单线程的Redis利用IO多路复用实现并发，IO多路复用是利用单个线程来同时监听多个文件描述符FD，并在某个FD可读、可写时得到通知，从而避免无效的等待，充分利用CPU资源。不过监听FD的方式、通知的方式又有多种实现

- select() //参数1int nfds是监听的最大fd + 1，接下来三个参数是读写异常事件的fd集合（fd_set结构体）,最后一个参数是超时事件，超过这个时间还没有可用的fd就结束阻塞
- poll() //参数1fds是监听的fd数组（poll_fd结构体，包括fd，监听类型，实际发生的事件类型），底层是链表实现，比起select最大1024个fd其理论无上限，但链表长时性能下降
- epoll

其中select和pool相当于是当被监听的数据准备好之后，他会把你监听的FD整个数据都发给你，你需要到整个FD中去找，哪些是处理好了的，需要通过遍历的方式，所以性能较差

而epoll，则相当于内核准备好了之后，把准备好的数据直接发送，省去了遍历的动作

epoll模式是对select和poll的改进，它提供了三个函数：

第一个是：**eventpoll**的函数，他内部包含两个东西

1. rb_root红黑树-> 记录的事要监听的FD，使用红黑树是因为其同样没有上限，且增删改查速度好

2. list_head一个链表-> 记录的是就绪的FD

紧接着调用**epoll_ctl**操作，将要监听的数据添加到rb_root上去，并且给每个fd设置一个监听函数，这个函数会在fd数据就绪时触发，就是准备好了，现在就把fd把数据添加到list_head中去

一开始在用户态创建一个空的events数组，当有数据准备就绪之后，我们的回调函数会把数据添加到list_head中去，再调用**epoll_wait**函数，当调用这个函数的时候，会去检查list_head，当然这个过程需要参考配置的等待时间，可以等一定时间，也可以一直等， 如果在此过程中，检查到了list_head中有数据会将数据添加到链表中，此时将数据放入到events数组中，并且返回对应的操作的数量，用户态的此时收到响应后，从events中拿到对应准备好的数据的节点，再去调用方法去拿数据

- 基于epoll实例中的红黑树保存要监听的FD，理论上无上限，而且增删改查效率都非常高
- 每个FD只需要执行一次epoll_ctl添加到红黑树，以后每次epol_wait无需传递任何参数，无需重复拷贝FD到内核空间
- 利用ep_poll_callback机制来监听FD状态，无需遍历所有FD，因此性能不会随监听的FD数量增多而下降

![1653982278727](.\原理篇.assets\1653982278727.png)

Redis在三种类型的事务之间进行IO多路复用

- 连接应答：处理客户端的连接请求
- 命令请求：处理客户端发送的指令，读写命令等
- 命令回复：把指令的返回数据传输给客户端，比如查询的数据

## Redis通信协议

Redis客户端同Redis服务端之间使用RESP协议（应用层协议，下层是TCP）进行通信

默认使用的依然是RESP2协议（以下简称RESP）。

在RESP中，通过首字节的字符来区分不同数据类型，常用的数据类型包括5种：

单行字符串：首字节是 ‘+’ ，后面跟上单行字符串，以CRLF（ "\r\n" ）结尾。例如返回"OK"： "+OK\r\n"

错误（Errors）：首字节是 ‘-’ ，与单行字符串格式一样，只是字符串是异常信息，例如："-Error message\r\n"

数值：首字节是 ‘:’ ，后面跟上数字格式的字符串，以CRLF结尾。例如：":10\r\n"

多行字符串：首字节是 ‘$’ ，表示二进制安全的字符串，第二个字节是字符串的大小，最大支持512MB

如果大小为0，则代表空字符串："$0\r\n\r\n"

如果大小为-1，则代表不存在："$-1\r\n"

数组：首字节是 ‘*’，后面跟上数组元素个数，再跟上元素，元素数据类型不限

可以直接用TCP连接到Redis服务端，手动模拟RESP协议进行通信

    //发送的指令是字符串数组形式的RESP
    private static void sendRequest(String ... args) {
        writer.println("*" + args.length);
        for (String arg : args) {
            writer.println("$" + arg.getBytes(StandardCharsets.UTF_8).length);
            writer.println(arg);
        }
        writer.flush();
    }

    //处理Redis服务器发送的RESP数据
    private static Object handleResponse() throws IOException {
        // 读取首字节
        int prefix = reader.read();
        // 判断数据类型标示
        switch (prefix) {
            case '+': // 单行字符串，直接读一行
                return reader.readLine();
            case '-': // 异常，也读一行
                throw new RuntimeException(reader.readLine());
            case ':': // 数字
                return Long.parseLong(reader.readLine());
            case '$': // 多行字符串
                // 先读长度
                int len = Integer.parseInt(reader.readLine());
                if (len == -1) {
                    return null;
                }
                if (len == 0) {
                    return "";
                }
                // 再读数据,读len个字节
                char[] buf = new char[len];
                reader.read(buf,0,len);
                return new String(buf);
            case '*':
                return readBulkString();
            default:
                throw new RuntimeException("错误的数据格式！");
        }
    }

    //处理RESP数组
    private static Object readBulkString() throws IOException {
        // 获取数组大小
        int len = Integer.parseInt(reader.readLine());
        if (len <= 0) {
            return null;
        }
        // 定义集合，接收多个元素
        List<Object> list = new ArrayList<>(len);
        // 遍历，依次读取每个元素
        for (int i = 0; i < len; i++) {
            list.add(handleResponse());
        }
        return list;
    }

## Redis垃圾回收

### 过期key清理

Redis数据库本身就是一个叫redisDb的结构体，包括dict和expire两个dict*指针，分别指向两个dict结构，第一个是key-value的dict，value可以是多种数据类型，第二个是key-ttl的dict，value只能是数字

对于过期的key，Redis采用两种方式删除，一种是惰性删除，在访问一个key的时候判断是否过期，过期了删除；另一个是周期删除，是一个定时任务，有SLOW和FAST两种模式，都是抽取key的形式，只有执行频率和执行周期的区别

SLOW模式规则：

- 执行频率受server.hz影响，默认为10，即每秒执行10次，每个执行周期100ms。
- 执行清理耗时不超过一次执行周期的25%.默认slow模式耗时不超过25ms
- 逐个遍历db，逐个遍历db中的bucket，抽取20个key判断是否过期
- 如果没达到时间上限（25ms）并且过期key比例大于10%，再进行一次抽样，否则结束

FAST模式规则（过期key比例小于10%不执行 ）：

- 执行频率受beforeSleep()调用频率影响，但两次FAST模式间隔不低于2ms
- 执行清理耗时不超过1ms
- 逐个遍历db，逐个遍历db中的bucket，抽取20个key判断是否过期
  如果没达到时间上限（1ms）并且过期key比例大于10%，再进行一次抽样，否则结束

### 内存淘汰

Redis内存到达上限时也可能主动删除某些key以释放内存，策略有

- noeviction： 不淘汰任何key，但是内存满时不允许写入新数据，默认就是这种策略。
- volatile-ttl： 对设置了TTL的key，比较key的剩余TTL值，TTL越小越先被淘汰
- allkeys-random：对全体key ，随机进行淘汰。也就是直接从db->dict中随机挑选
- volatile-random：对设置了TTL的key ，随机进行淘汰。也就是从db->expires中随机挑选。
- allkeys-lru： 对全体key，基于LRU算法进行淘汰
- volatile-lru： 对设置了TTL的key，基于LRU算法进行淘汰
- allkeys-lfu： 对全体key，基于LFU算法进行淘汰
- volatile-lfu： 对设置了TTL的key，基于LFU算法进行淘汰

LRU是最少最近使用，优先淘汰最近访问时间离现在最远的key，RedisObject中的lru成员记录了最近一次的访问时间，以s为单位

LFU是最少频率使用。会统计每个key的访问频率，优先淘汰被访问频率低的key，同样用lru成员记录，此时高16位记录最近一次访问时间，以分钟为单位，低8位记录逻辑访问次数，叫做逻辑访问次数是因为它不是真实的访问次数，而是计算得出的，流程是

- 生成0~1之间的随机数R
- 计算 (旧次数 * lfu_log_factor + 1)，记录为P
- 如果 R < P ，则计数器 + 1，且最大不超过255
- 访问次数会随时间衰减，距离上一次访问时间每隔 lfu_decay_time 分钟，计数器 -1
