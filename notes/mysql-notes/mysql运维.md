# MySQL运维

## MySQL日志

MySQL的日志包括错误日志，binlog二进制日志，查询日志和慢查询日志

查看MySQL的各种目录

    SELECT @@basedir, @@datadir, @@innodb_data_home_dir, @@innodb_log_group_home_dir;

上述命令会输出MySQL的基础目录（@@basedir）、数据目录（@@datadir）、InnoDB数据文件目录（@@innodb_data_home_dir）和InnoDB日志文件组目录（@@innodb_log_group_home_dir）等

下面的命令查看配置文件的加载顺序，Linux用grep，Windows用findstr

    mysql --help --verbose | grep my.cnf
    mysql --help --verbose | findstr my.cnf

任何通过修改配置文件修改的系统变量必须重启MySQL进程才能生效，使用SET的可以立即生效但重启后重置

### 错误日志

错误日志的默认位置是`/var/log/mysqld.log`，使用如下命令可以查看对应系统变量，保存了实际的位置

    show variables like '%log_error%';

### binlog

二进制日志（BINLOG）记录了本MySQL进程下所有数据库的所有的 DDL（数据定义语言）语句和 DML（数据操纵语言）语句，但不包括数据查询（SELECT、SHOW）语句，因为这些语句不会对数据库内容有修改。作用一是灾难时的数据恢复，二是MySQL的主从复制。MySQL8之后默认binlog开启，使用如下命令查看相关系统变量

    show variables like '%log_bin%';

- log_bin_basename：当前数据库服务器的binlog日志的基础名称(前缀)，具体的binlog文件名需要再该basename的基础上加上编号(编号从000001开始)
- log_bin_index：binlog的索引文件，里面记录了当前服务器关联的binlog文件有哪些

binlog的格式有

- STATEMENT：基于SQL语句的日志记录，记录的是SQL语句，对数据进行修改的SQL都会记录在日志文件中
- ROW：基于行的日志记录，记录的是每一行的数据变更。（默认）
- MIXED：混合了STATEMENT和ROW两种格式，默认采用STATEMENT，在某些特殊情况下会自动切换为ROW进行记录

用以下命令查看，配置也是修改/etc/my.cnf 中的 binlog_format 参数或者直接SET对应系统变量

    show variables like '%binlog_format%';

日志是二进制的，查看需要使用mysqlbinlog命令行客户端

    mysqlbinlog [ 参数选项 ] logfilename
    参数选项：
    -d 指定数据库名称，只列出指定的数据库相关操作。
    -o 忽略掉日志中的前n行命令。
    -v 将行事件(数据变更)重构为SQL语句
    -vv 将行事件(数据变更)重构为SQL语句，并输出注释信息

删除日志可以在MySQL用以下几种SQL语句

- reset master：删除全部 binlog 日志，删除之后，日志编号，将从 binlog.000001重新开始
- purge master logs to 'binlog.*'：删除 \* 编号之前的所有日志
- purge master logs before 'yyyy-mm-dd hh24:mi:ss'：删除日志为 "yyyy-mm-dd hh24:mi:ss" 之前产生的所有日志

或者设置此变量设置自动过期时间

    show variables like '%binlog_expire_logs_seconds%';

### 查询日志，慢查询日志

查询日志中记录了客户端的所有SQL语句（binlog不包括查询类语句），默认关闭

要开启可以修改/etc/my.cnf 文件，添加以下内容

    #该选项用来开启查询日志 ， 可选值 ： 0 或者 1 ； 0 代表关闭， 1 代表开启
    general_log=1
    #设置日志的文件名 ， 如果没有指定， 默认的文件名为 host_name.log，日志在MySQL的数据存放目录（默认/var/lib/mysql/）
    general_log_file=mysql_query.log

慢查询日志记录了所有执行时间超过参数 long_query_time 设置值（默认10，单位s）并且扫描记录数不小于min_examined_row_limit 的所有的SQL语句的日志

开启慢查询日志同样修改配置文件

    #慢查询日志
    slow_query_log=1
    #执行时间参数
    long_query_time=2

默认不记录管理语句和未使用索引的查询，添加对应项开启

    #记录执行较慢的管理语句
    log_slow_admin_statements =1
    #记录执行较慢的未使用索引的语句
    log_queries_not_using_indexes = 1

## 主从

主从复制是指将主数据库的 DDL 和 DML 操作通过二进制日志传到从库服务器中，然后在从库上对这些日志重新执行（也叫重做），从而使得从库和主库的数据保持同步。使用主从可以提高抗风险能力，把服务转移到主库；配置读写分离，提高并发；在从库备份，避免影响主库

主从复制的核心就是日志里的binlog，复制的行为分成三步

1. Master 主库在事务提交时，会把数据变更记录在二进制日志文件 Binlog 中。
2. slave读取主库的二进制日志文件 Binlog ，写入到从库的中继日志 Relay Log 。
3. slave重做中继日志中的事件，将改变反映它自己的数据。

### 搭建

#### 主库

1. 修改配置文件 /etc/my.cnf
   
    #mysql 服务ID，保证整个集群环境中唯一，取值范围：1 – 232-1，默认为1
    server-id=1
    #是否只读,1 代表只读, 0 代表读写
    read-only=0
    #忽略的数据, 指不需要同步的数据库
    #binlog-ignore-db=mysql
    #指定同步的数据库
    #binlog-do-db=db01

2. 重启MySQL服务器
   
    systemctl restart mysqld

3. 登录mysql，创建远程连接的账号，并授予主从复制权限
   
    #创建itcast用户，并设置密码，该用户可在任意主机连接该MySQL服务，'%'表示任何主机地址都可以用这个账号连接
    CREATE USER 'itcast'@'%' IDENTIFIED WITH mysql_native_password BY 'Root@123456';
    #为 'itcast'@'%' 用户分配主从复制权限，*.*意思是所有数据库的所有表
    GRANT REPLICATION SLAVE ON *.* TO 'itcast'@'%';

4. 通过指令，查看二进制日志坐标
   
    SHOW MASTER STATUS;

其中

- file : 从哪个日志文件开始推送日志文件
- position ： 从哪个位置开始推送日志
- binlog_ignore_db : 指定不需要同步的数据库

#### 从库

1. 修改配置文件 /etc/my.cnf
   
    #mysql 服务ID，保证整个集群环境中唯一，取值范围：1 – 2^32-1，和主库不一样即可
    server-id=2
    #是否只读,1 代表只读, 0 代表读写
    read-only

2. 重启MySQL服务器
   
    systemctl restart mysqld

3. 登录MySQL配置主库，如果是8.0.23 之前的版本，开头的REPLICATION SOURCE和其余的所有SORCE都改成MASTER
   
    CHANGE REPLICATION SOURCE TO SOURCE_HOST='192.168.200.200', SOURCE_USER='itcast', SOURCE_PASSWORD='Root@123456' SOURCE_LOG_FILE='binlog.000004', SOURCE_LOG_POS=663;

4. 开启主从同步
   
    start replica ; #8.0.22之后
    start slave ; #8.0.22之前

5. 查看主从同步状态
   
    show replica status ; #8.0.22之后
    show slave status ; #8.0.22之前

## 分库，分表

过大的数据库/表性能会严重下降，需要拆表

分库，分表的思路有两种，一种是垂直式，也就是根据不同的列拆分，用相同的id来标识这是同一行的数据。另一种是水平式，每个库/表的结构都相同，只是都存储一部分数据，具体数据存在那个部分，由特定的算法决定

MyCat是一个分片管理工具，构建了逻辑库/逻辑表给用户使用，并把操作映射到对应的物理库/物理表，是一个透明的中间层

在MyCat中，当执行一条SQL语句时，MyCat需要进行SQL解析、分片分析、路由分析、读写分离分析等操作，最终经过一系列的分析决定将当前的SQL语句到底路由到那几个(或哪一个)节点数据库，数据库将数据执行完毕后，如果有返回的结果，则将结果返回给MyCat，最终还需要在MyCat中进行结果合并、聚合处理、排序处理、分页处理等操作，最终再将结果返回给客户端

配置文件包括

- schema.xml ：是MyCat中最重要的配置文件之一 , 涵盖了MyCat的逻辑库 、逻辑表 、分片规则、分片节点及数据源的配置
- rule.xml中定义所有拆分表的规则, 指定使用分片算法, 不同的参数等
- server.xml包含了MyCat的系统配置信息（类似mysql系统变量），和用户配置

在schema.xml中\<schema>表示数据库，\<table>表示表，其中的name指定逻辑表名称，dateNode指定数据节点名称（在\<dateNode>标签下会把标签和实际主机\<dateHost>关联起来，并在\<dateHost>配置实际的数据库地址）

执行查询的SQL时，会把SQL路由到对应的物理节点，但如果SQL查询的多个表是跨物理节点的，就无法在这个物理节点上查到该表出错。对于经常需要和其它表一起查询的表，推荐转化为全局表在每个物理节点都存储，全局表需要在\<table>里指定type = "global"

### 分片规则

主要是针对水平分片（垂直分片直接按表/列分片即可）

在MyCat使用\<tableRule>的\<rule>指定分片的方法，其中\<columns>是分片参考列，\<aglorithm>是算法，由\<function>定义

范围分片，使用某一列（一般是id）的值，划定范围分片

取模分片，设定要分到几个dataNode就对几取模，得到的就是物理节点索引（0开始）

一致性hash分片，一致性哈希，相同的哈希因子计算值总是被划分到相同的分区表中，不会因为分区节点的增加而改变原来数据的分区位置

枚举分片：通过在配置文件中枚举\<columns>可能的值, 手动指定数据分布到不同数据节点上

应用指定算法：在运行阶段由应用自主决定路由到那个分片 , 例如直接根据字符子串（必须是数字）计算分片号

固定分片hash算法：和取模分片类似，但是分片总长度必须是2或者2的倍数，因此可以采用位掩码+&运算确定hash的位置，在配置中指定对应分片区间的物理节点

字符串hash解析算法：截取字符串中的指定位置的子字符串, 进行hash算法， 算出分片

按天分片算法：按照日期及对应的时间周期来分片

按自然月分片：为按照月份来分片, 每个自然月为一个分片，如果需要储存一年的数据必须要12个dataNode

## 读写分离

MyCat同样可以配置MySQL主从的读写分离

    <!-- 配置逻辑库 -->
    <schema name="ITCAST_RW" checkSQLschema="true" sqlMaxLimit="100" dataNode="dn7"></schema>
    <dataNode name="dn7" dataHost="dhost7" database="itcast" />
    <dataHost name="dhost7" maxCon="1000" minCon="10" balance="1" writeType="0" dbType="mysql" dbDriver="jdbc" switchType="1" slaveThreshold="100">
        <heartbeat>select user()</heartbeat>
        <writeHost host="master1" url="jdbc:mysql://192.168.200.211:3306?useSSL=false&serverTimezone=Asia/Shanghai&characterEncoding=utf8" user="root" password="1234" >
            <readHost host="slave1" url="jdbc:mysql://192.168.200.212:3306?useSSL=false&serverTimezone=Asia/Shanghai&characterEncoding=utf8" user="root" password="1234" />
        </writeHost>
    </dataHost>

在\<writeHost>下的\<readHost>标签指定了读取的从库的位置

\<dataHost>的参数 balance是读写分离的模式，取值有4种，只有1和3是读写分离

- 0 不开启读写分离机制 , 所有读操作都发送到当前可用的writeHost上
- 1 全部的readHost 与 备用的writeHost 都参与select 语句的负载均衡（主要针对于双主双从模式）
- 2 所有的读写操作都随机在writeHost , readHost上分发
- 3 所有的读请求随机分发到writeHost对应的readHost上执行, writeHost不负担读压力

### 多个主从

单个主从节点只需要从节点向主节点同步数据，多个则不同主节点之间也要互相同步，和从节点同步主节点一样，使用CHANGE命令

MyCat要使用多主多从，只需要写多个\<writeHost>即可，多个\<writeHost>就是xml里自上而下的顺序

\<dataHost>的参数 balance 应该是1

参数writeType是写操作的配置

- 0 : 写操作都转发到第1台writeHost, writeHost1挂了, 会切换到writeHost2上;
- 1 : 所有的写操作都随机地发送到配置的writeHost上

参数switchType为1时，主库挂掉一个之后可以自动切换，-1时不自动切换
