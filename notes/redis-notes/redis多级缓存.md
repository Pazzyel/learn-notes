# 多级缓存

多级缓存是利用充分请求的各个环节缓存，从客户端到服务端依次为

- 浏览器本地缓存
- Nginx缓存
- 由Nginx查询的Redis缓存（不经过服务端）
- JVM进程缓存
- 数据库

## nginx本地缓存

OpenResty为Nginx提供了**shard dict**的功能，可以在nginx的多个worker之间共享数据，实现缓存功能

在nginx配置文件的**http**下开启共享词典，名字是item_cache 大小150m

    lua_shared_dict item_cache 150m;

操作这个共享词典

    -- 获取本地缓存对象
    local item_cache = ngx.shared.item_cache
    -- 存储, 指定key、value、过期时间，单位s，默认为0代表永不过期
    item_cache:set('key', 'value', 1000)
    -- 读取
    local val = item_cache:get('key')

## nginx直接查询Redis

要使用OpenRest的配置nginx功能，需要导入对应模块，在**http**下配置

    #lua 模块
    lua_package_path "/usr/local/openresty/lualib/?.lua;;";
    #c模块
    lua_package_cpath "/usr/local/openresty/lualib/?.so;;";

OpenRest提供直接查询redis的功能，如下工具文件common.lua可以直接提供read_redis()方法供调用以查询redis，以同样方法用table导出

    -- 导入redis
    local redis = require('resty.redis')
    -- 初始化redis
    local red = redis:new()
    red:set_timeouts(1000, 1000, 1000)
    
    -- 关闭redis连接的工具方法，其实是放入连接池
    local function close_redis(red)
        local pool_max_idle_time = 10000 -- 连接的空闲时间，单位是毫秒
        local pool_size = 100 --连接池大小
        local ok, err = red:set_keepalive(pool_max_idle_time, pool_size)
        if not ok then
            ngx.log(ngx.ERR, "放入redis连接池失败: ", err)
        end
    end
    
    -- 查询redis的方法 ip和port是redis地址，key是查询的key
    local function read_redis(ip, port, key)
        -- 获取一个连接
        local ok, err = red:connect(ip, port)
        if not ok then
            ngx.log(ngx.ERR, "连接redis失败 : ", err)
            return nil
        end
        -- 查询redis
        local resp, err = red:get(key)
        -- 查询失败处理
        if not resp then
            ngx.log(ngx.ERR, "查询Redis失败: ", err, ", key = " , key)
        end
        --得到的数据为空处理
        if resp == ngx.null then
            resp = nil
            ngx.log(ngx.ERR, "查询Redis数据为空, key = ", key)
        end
        close_redis(red)
        return resp
    end
    
    -- 封装函数，发送http请求，并解析响应
    local function read_http(path, params)
        local resp = ngx.location.capture(path,{
            method = ngx.HTTP_GET,
            args = params,
        })
        if not resp then
            -- 记录错误信息，返回404
            ngx.log(ngx.ERR, "http查询失败, path: ", path , ", args: ", args)
            ngx.exit(404)
        end
        return resp.body
    end

## nginx查询Tomcat

nginx的配置文件是conf目录下的nginx.conf。其中的http-server-listen是nginx的监听端口http-server-location是请求映射路径

    location  /api/item {
        # 默认的响应类型
        default_type application/json;
        # 响应结果由lua/item.lua文件来决定
        content_by_lua_file lua/item.lua;
    }

表示对监听请求的IP:port/api/item路径的响应，响应类型是json，响应逻辑由lua/item.lua文件来决定

OpenRest利用lua来编辑nginx服务。对于不同请求路径的参数有不同的方法接受

- 路径参数，在路径使用正则表达式匹配，保存到数组ngx.var
- 请求头：ngx.req.get_headers()，返回table
- GET请求参数：ngx.req.get_uri_args()，返回table
- POST表单参数：ngx.req.get_post_args()，返回table，需要先ngx.req.read_body()获取请求体
- JSON参数：ngx.req.get_body_data()，返回JSON的string，需要先ngx.req.read_body()获取请求体

nginx提供了发送HTTP请求的方法

    local function read_http(path, params)
        local resp = ngx.location.capture(path,{
            method = ngx.HTTP_GET,
            args = params,
        })
        if not resp then
            -- 记录错误信息，返回404
            ngx.log(ngx.ERR, "http请求查询失败, path: ", path , ", args: ", args)
            ngx.exit(404)
        end
        return resp.body
    end
    -- 将方法导出
    local _M = {  
        read_http = read_http
        read_redis = read_redis
    }  
    return _M

其中`ngx.location.capture()`用于发送HTTP请求，path是nginx监听的路径，发送的IP:port是对应路径的代理，method是请求类型，args是请求参数，返回的resp是响应，可以用resp.status获取状态码，resp.header获取响应头，resp.body获取响应体。导出方法导出的是一个table，可以用common.read_http获取函数体（comon是文件名）

如果当前nginx处于虚拟容器（如wsl）而后端服务部署在宿主机上，IP应该填写宿主机的IP（如wsl可以用`ip route | grep default`确定宿主机IP映射）

cjson模块用于lua table和json的相互转换，`cjson.decode()`把json反序列化为table，`cjson.encode()`把table序列化为json

完整的item.lua完成从nginx本地缓存->redis->tomcat的多级缓存流程

    -- 导入common函数库
    local common = require('common')
    local read_http = common.read_http
    local read_redis = common.read_redis
    -- 导入cjson库
    local cjson = require('cjson')
    -- 导入共享词典，本地缓存
    local item_cache = ngx.shared.item_cache
    
    -- 封装查询函数
    function read_data(key, expire, path, params)
        -- 查询本地缓存
        local val = item_cache:get(key)
        if not val then
            ngx.log(ngx.ERR, "本地缓存查询失败，尝试查询Redis， key: ", key)
            -- 查询redis
            val = read_redis("127.0.0.1", 6379, key)
            -- 判断查询结果
            if not val then
                ngx.log(ngx.ERR, "redis查询失败，尝试查询http， key: ", key)
                -- redis查询失败，去查询http
                val = read_http(path, params)
            end
        end
        -- 查询成功，把数据写入本地缓存
        item_cache:set(key, val, expire)
        -- 返回数据
        return val
    end
    
    -- 获取路径参数
    local id = ngx.var[1]
    
    -- 查询商品信息
    local itemJSON = read_data("item:id:" .. id, 1800,  "/item/" .. id, nil)
    -- 查询库存信息
    local stockJSON = read_data("item:stock:id:" .. id, 60, "/item/stock/" .. id, nil)
    
    -- JSON转化为lua的table
    local item = cjson.decode(itemJSON)
    local stock = cjson.decode(stockJSON)
    -- 组合数据
    item.stock = stock.stock
    item.sold = stock.sold
    
    -- 把item序列化为json 返回结果
    ngx.say(cjson.encode(item))

在http-server项下配置以使用该lua的逻辑进行响应

    location ~ /api/item/(\d+) {
        default_type application/json;
        content_by_lua_file lua/item.lua;
    }

### Tomcat负载均衡

如果nginx自己查询Redis未命中，才把请求打到Tomcat

可以让nginx为Tomcat集群进行负载均衡，为了保证一个请求能够由同一台Tomcat服务（有缓存），应该对代理路径计算进行负载均衡

定义如下的upstream在多个tomcat间根据请求路径的hash进行负载均衡

    upstream tomcat-cluster {
        hash $request_uri;
        server 192.168.150.1:8081;
        server 192.168.150.1:8082;
    }

把代理路径改成该upstream

    location /item {
        proxy_pass http://tomcat-cluster;
    }

## JVM进程缓存

请求打到Tomcat后，服务端依然可以依靠JVM进程缓存避免对数据库的读取，利用Caffeine框架来实现JVM进程缓存

获取缓存类

    Cache<String, String> cache = Caffeine.newBuilder().build();

添加缓存

    cache.put("key", "value");

查询缓存

    String value = cache.getIfPresent("key");
    String defaultValue = cache.get("defaultKey", key -> {
        return "defaultValue";//如果缓存没有命中，执行lambda表达式返回的项
    });

### Caffeine缓存驱逐策略

基于容量

    // 设置缓存大小上限为1，超过就驱逐旧的缓存
    Cache<String, String> cache = Caffeine.newBuilder().maximumSize(1).build(); 

基于时间

    // 设置缓存有效期为10s，超过就驱逐旧的缓存
    Cache<String, String> cache = Caffeine.newBuilder().expireAfterWrite(Duration.ofSeconds(10)).build();

基于引用：通过将缓存设置为软引用或弱引用，利用GC来回收缓存数据，性能较差

在默认情况下，当一个缓存元素过期的时候，Caffeine不会自动立即将其清理和驱逐。而是在一次读或写操作后，或者在空闲时间完成对失效数据的驱逐

## 缓存同步

对于同步双写，先更新数据库再删缓存。而这里介绍异步缓存同步，也就是更新数据库后的一段时间再更新缓存。一种实现是利用MQ，更新数据库时发布更新缓存的消息，缓存操作的线程监测到消息后更新缓存。另一种是使用canal监听数据库的数据变更情况，监测到数据变化就通知缓存线程更新缓存，这里介绍第二种方案

canal伪装成mysql的slave节点，通过监听master的binlog变化来获取数据更新的消息

首先需要开启mysql的binlog，在mysql容器挂载的日志文件下添加这两行

    log-bin=/var/lib/mysql/mysql-bin
    binlog-do-db=heima

拉取镜像`docker pull canal/canal-server`

    docker run -d --name canal \
    -p 11111:11111 \
    -e canal.destinations=rdpcanal \
    -e canal.instance.master.address=mysql:3306 \
    -e canal.instance.dbUsername=canal \
    -e canal.instance.dbPassword=canal \
    -e canal.instance.connectionCharset=UTF-8 \
    -e canal.instance.tsdb.enable=true \
    -e canal.instance.gtidon=false \
    -e canal.instance.filter.regex=.*\\..* \
    --network rdp \
    canal/canal-server:latest

请拉取最新镜像，过早的版本可能无法启动

- destinations用于标明这个canal
- filter.regex用于表明监听的表，`.*\\..* \`表示所有表
- network 直接加入该网络，网络内部的容器通信使用内部端口

使用某第三方canal客户端进行canal的简易操作，在pom.xml引入依赖

    <dependency>
        <groupId>top.javatool</groupId>
        <artifactId>canal-spring-boot-starter</artifactId>
        <version>1.2.1-RELEASE</version>
    </dependency>

配置yaml

    canal:
        destination: rdpcanal # canal的集群名字，要与安装canal时设置的名称一致
        server: 127.0.0.1:11111 # canal服务地址

还要通过实体类的@Id，@Column注解建立实体类和数据库字段的映射

通过一个实现EntryHandler的类来接受canal的消息，@CanalTable("tb_item")用于指定监听的表，redisHandler是自己编写的类，底层调用redisTemplate进行redis操作

    @CanalTable("tb_item")
    @Component
    public class ItemHandler implements EntryHandler<Item> {
    
        @Autowired
        private RedisHandler redisHandler;
        @Autowired
        private Cache<Long, Item> itemCache;
    
        @Override
        public void insert(Item item) {
            // 写数据到JVM进程缓存
            itemCache.put(item.getId(), item);
            // 写数据到redis
            redisHandler.saveItem(item);
        }
    
        @Override
        public void update(Item before, Item after) {
            // 写数据到JVM进程缓存
            itemCache.put(after.getId(), after);
            // 写数据到redis
            redisHandler.saveItem(after);
        }
    
        @Override
        public void delete(Item item) {
            // 删除数据到JVM进程缓存
            itemCache.invalidate(item.getId());
            // 删除数据到redis
            redisHandler.deleteItemById(item.getId());
        }
    }

这个客户端会一直每秒轮询消息，即使没有消息也会记录日志，影响了日志的阅读，可以在resource/logback-spring.xml配置屏蔽这个类记录的日志

    <configuration>
        <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
            <encoder>
                <pattern>%d{HH:mm:ss.SSS} %-5level [%thread] %logger{36} : %msg%n</pattern>
            </encoder>
        </appender>
        <logger name="top.javatool.canal.client.client.AbstractCanalClient" level="WARN" additivity="false">
            <appender-ref ref="CONSOLE"/>
        </logger>
        <root level="INFO">
            <appender-ref ref="CONSOLE"/>
        </root>
    </configuration>
