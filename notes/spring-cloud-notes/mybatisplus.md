# MyBatisPlus

引入SpringBoot的starter，已经包含MyBatis的starter

    <dependency>
        <groupId>com.baomidou</groupId>
        <artifactId>mybatis-plus-boot-starter</artifactId>
        <version>3.5.3.1</version>
    </dependency>

## BaseMapper

对应MyBatis的Mapper，实现了BaseMapper\<T>后，其AOP的代理类就自动包含了BaseMapper提供的所有单表CURD方法

BaseMapper\<T>，泛型应当是你要操作的表对应的实体类，默认情况下

- MybatisPlus会把PO实体的类名驼峰转下划线作为表名
- MybatisPlus会把PO实体的所有变量名驼峰转下划线作为表的字段名，并根据变量类型推断字段类型，如果字段以isXXX开头，is会被去除
- MybatisPlus会把名为id的字段作为主键

需要自行指定，使用以下注解

- @TableName，用于实体类，value指定其对应的表名（还包含其他的比如数据库名等）
- @TableId，实体类的主键字段，还可以指定type为想要的id类型，如IdType.AUTO自增，IdType.INPUT手动输入，IdType.ASSIGN_ID雪花ID（默认）
- @TableField，实体类一般字段，value指定其对应的数据库列名，一般在自动转换无法转换时使用，如果名称和数据库关键字冲突，这里可以加上``转义，还包括如exist（指定这个字段是否在数据库存在）等其它项

可以使用yaml配置文件

    mybatis-plus:
        type-aliases-package: com.mp.domain.po # 配置别名扫描包，该包下的类名以其的最后一部分为别名，默认不配置（只有这一项没有默认值）
        mapper-locations: "classpath*:/mapper/**/*.xml" # Mapper.xml文件地址，当前这个是默认值，这里的xml会被加载，和mybatis的配置一致
        global-config:
            db-config:
                id-type: auto # 全局id类型为自增长

## 条件构造器Wrapper\<T>

用于构建复杂的WHERE条件，Wrapper是条件构造的抽象类，其下有很多默认实现，AbstractWrapper提供了where中包含的所有条件构造方法，QueryWrapper在AbstractWrapper的基础上拓展了一个select方法，允许指定查询字段，UpdateWrapper在AbstractWrapper的基础上拓展了一个set方法，允许指定SQL中的SET部分

一般情况下，这些条件方法还有第一个参数是boolean的版本，为true是才执行，类似xml的\<if>标签，一般用于判断这个字段是否存在

Wrapper支持链式调用，调用一个方法之后返回this

Wrapper的泛型用于编译时类型检查，确保你在构建查询时使用的字段名和条件与 类 实体的属性匹配

### QueryWrapper

     QueryWrapper<User> wrapper = new QueryWrapper<User>()
            .select("id", "username", "info", "balance")
            .like("username", "o")
            .ge("balance", 1000);

    List<User> users = userMapper.selectList(wrapper);

QueryWrapper应该先调用`select()`指定查询字段，再调用AbstractWrapper继承来的where条件

QueryWrapper也可以传给UpdateWrapper，实际上作为Wrapper，只使用了其中的where条件

### UpdateWarpper

基本的`update(T,Warpper<T>)`只能之间把实体类的值赋值到数据库行，部分UPDATE需要用到数据库行本身的数据，此时就需要先SELECT再UPDATE，性能不佳，一般情况下都是通过直接在SET的SQL里更新，一条语句完成，例如

    UPDATE user SET balance = balance - 200 WHERE id in (1, 2, 4);

UpdateWarpper提供`setSql(String)`方法，可以直接以字符串形式传入SET后面那部分SQL语句

    UpdateWrapper<User> wrapper = new UpdateWrapper<User>()
            .setSql("balance = balance - 200") // SET balance = balance - 200
            .in("id", ids);

### LambdaQueryWrapper，LambdaUpdateWrapper

前面介绍的Warpper需要在构造条件中写死字段名称，耦合度较高。因此提供了LambdaXXXWrapper的形式，只需要以lambda方法引用的形式传入字段对应的get方法，MybatisPlus根据反射获取方法名称，去掉get前缀并小写首字母，把这个作为字段名

    QueryWrapper<User> wrapper = new QueryWrapper<>().lambda()
            .select(User::getId, User::getUsername, User::getInfo, User::getBalance)
            .like(User::getUsername, "o")
            .ge(User::getBalance, 1000);

## 自定义SQL

自定义SQL就是把条件构造器的条件转换为SQL片段，方便的在Java文件中获取SQL的WHERE条件，不需要在xml中用\<foreach>拼接

    void testCustomWrapper() {
        // 1.准备自定义查询条件
        List<Long> ids = List.of(1L, 2L, 4L);
        QueryWrapper<User> wrapper = new QueryWrapper<User>().in("id", ids);

        // 2.调用mapper的自定义方法，直接传递Wrapper
        userMapper.deductBalanceByIds(200, wrapper);
    }

    @Select("UPDATE user SET balance = balance - #{money} ${ew.customSqlSegment}") // ew.customSqlSegment的值就是WHERE id in (1,2,4)
    void deductBalanceByIds(@Param("money") int money, @Param("ew") QueryWrapper<User> wrapper);

自定义SQL还可以用于多表查询

    QueryWrapper<User> wrapper = new QueryWrapper<User>()
            .in("u.id", List.of(1L, 2L, 4L))
            .eq("a.city", "北京");

    @Select("SELECT u.* FROM user u INNER JOIN address a ON u.id = a.user_id ${ew.customSqlSegment}")
    List<User> queryUserByWrapper(@Param("ew")QueryWrapper<User> wrapper);

## IService

Service接口及默认实现是对BaseMapper操作的进一步封装

通用接口为IService，默认实现为ServiceImpl，其中封装的方法可以分为以下几类：

- save：新增
- remove：删除
- update：更新
- get：查询单个结果
- list：查询集合结果
- count：计数
- page：分页查询

让Service类继承ServiceImpl\<M,T>可以让其继承上述方法直接进行数据库操作，泛型M是实体类T的Mapper类型，该Mapper类必须继承BaseMapper\<T>。如果其是成员变量必须为final（requiredArgsConstructor就是根据final关键字创建构造方法的）

由于混淆了Service和Mapper层，注入其它Service可能还会发生循环依赖问题，因此IService的使用一直有争议

### Lambda查询

一般情况下，需要先构建LambdaQueryWarpper，再使用IService的list方法

    LambdaQueryWrapper<User> wrapper = new QueryWrapper<User>().lambda()
            .like(username != null, User::getUsername, username)
            .eq(status != null, User::getStatus, status)
            .ge(minBalance != null, User::getBalance, minBalance)
            .le(maxBalance != null, User::getBalance, maxBalance);

    List<User> users = userService.list(wrapper);

有一种简化写法，直接再IService上调用`lambdaQuery()`，构造条件后立刻查询并返回结果，结尾的`list()`和本来要调用的IService的查询方法相同，也可以是`one()`或者`count()`

    List<User> users = userService.lambdaQuery()
            .like(username != null, User::getUsername, username)
            .eq(status != null, User::getStatus, status)
            .ge(minBalance != null, User::getBalance, minBalance)
            .le(maxBalance != null, User::getBalance, maxBalance)
            .list();

Update也有对应的`lambdaUpdate()`

    userService.lambdaUpdate()
            .set(User::getBalance, remainBalance) // 更新余额
            .set(remainBalance == 0, User::getStatus, 2) // 动态判断，是否更新status
            .eq(User::getId, id)
            .eq(User::getBalance, user.getBalance()) // 乐观锁
            .update();

### 批量插入

MyBatisPlus的Mapper并没有提供批量插入的接口，Service层提供了`saveBatch()`，但只是基于PrepareStatement的预编译模式，然后批量提交。只连接一次数据库但是还是有多条INSERT语句。要想批量插入性能高，应该使用一条INSERT语句完成

MySQL在一个事务内的多条插入可以进行SQL优化。MySQL的客户端连接参数中有参数：rewriteBatchedStatements，开启后才会重写SQL进行优化

在连接到MySQL的url上把对应参数变成true

    spring:
        datasource:
            url: jdbc:mysql://127.0.0.1:3306/mp?useUnicode=true&characterEncoding=UTF-8&autoReconnect=true&serverTimezone=Asia/Shanghai&rewriteBatchedStatements=true
            driver-class-name: com.mysql.cj.jdbc.Driver
            username: root
            password: xxxxxx

开启此功能，InnoDB会把多条单个的INSERT优化为一条批量的INSERT

## 工具

### 代码生成器

直接通过数据库表的列生成对应实体类，Mapper等

    <dependency>
        <groupId>com.baomidou</groupId>
        <artifactId>mybatis-plus-generator</artifactId>
        <version>3.5.13</version>
    </dependency>

在CodeGenerator.java的main方法进行代码生成器编码

    public static void main(String[] args) {
        FastAutoGenerator.create("url", "username", "password")
                .globalConfig(builder -> {
                    builder.author("baomidou") // 设置作者
                            .enableSwagger() // 开启 swagger 模式
                            .outputDir("D://"); // 指定输出目录
                })
                .dataSourceConfig(builder ->
                        builder.typeConvertHandler((globalConfig, typeRegistry, metaInfo) -> {
                            int typeCode = metaInfo.getJdbcType().TYPE_CODE;
                            if (typeCode == Types.SMALLINT) {
                                // 自定义类型转换
                                return DbColumnType.INTEGER;
                            }
                            return typeRegistry.getColumnType(metaInfo);
                        })
                )
                .packageConfig(builder -> builder 
                        .parent("com.baomidou.mybatisplus") //设置父包模块名和对应的子包
                        .entity("entity")
                        .mapper("mapper")
                        .service("service")
                        .serviceImpl("service.impl")
                        .xml("mapper.xml")
                )
                .strategyConfig(builder ->
                        builder.addInclude("t_simple") // 设置需要生成的表名
                                .addTablePrefix("t_", "c_") // 设置过滤表前缀
                )
                .templateEngine(new FreemarkerTemplateEngine()) // 使用Freemarker引擎模板，默认的是Velocity引擎模板
                .execute();
    }

### 静态工具类

MybatisPlus3.5.3版本之后提供一个静态工具类：Db，其中的一些静态方法与IService中方法签名基本一致，避免Service循环调用的循环依赖问题

Db除了INSERT，UPDATE类的方法外，因为是静态类，其余方法必须额外传入一个Class\<T>（就是你要操作的表的对应实体类的class），来找到对应的表

### 逻辑删除

逻辑删除就是在表中有一个deleted列，删除把是把这一行的该字段UPDATE为1，而不是DELETE这行，同时在SELECT是去掉所有deleted = 1的行。MyBatisPlus可以把删除和查询的方法配置为逻辑删除

    mybatis-plus:
        global-config:
            db-config:
            logic-delete-field: deleted # 全局逻辑删除的实体字段名(since 3.3.0,配置后可以忽略不配置步骤2)
            logic-delete-value: 1 # 逻辑已删除值(默认为 1)
            logic-not-delete-value: 0 # 逻辑未删除值(默认为 0)

逻辑删除会导致数据库列越来越多，影响查询性能，不太推荐采用，如果数据不能删除，可以采用把数据迁移到其它表的办法

### 自定义枚举类

某些实体类字段如状态等一般可以用Java枚举类表示，包含id和对应的描述，数据库只储存id

要让MyBatisPlus自动转换数据库整数为Java枚举类，必须配置

    mybatis-plus:
        configuration:
            default-enum-type-handler: com.baomidou.mybatisplus.core.handlers.MybatisEnumTypeHandler

在枚举类中，用@EnumValue标识数据库储存的字段，用@JsonValue标识JSON序列化使用的字段

这里数据库储存的是value，JSON序列化使用desc

    public enum UserStatus {
        NORMAL(1, "正常"),
        FREEZE(2, "冻结");

        @EnumValue
        private final int value;
        @JsonValue
        private final String desc;

        UserStatus(int value, String desc) {
            this.value = value;
            this.desc = desc;
        }
    }

### JSON处理器

在数据库的JSON类型，MyBatis查出来默认是String，要操作JSON内的数据很不方便。如果使用实体类储存JSON类型，就必须在INSERT前序列化成JSON，查出来后反序列化为实体类

MybatisPlus提供了很多特殊类型字段的类型处理器，解决特殊字段类型与数据库类型转换的问题。例如处理JSON就可以使用JacksonTypeHandler处理器

对于JSON类型，如果我们自己定义了对应的实体类，就必须在这个实体类的字段上添加注解`@TableField(typeHandler = JacksonTypeHandler.class)`表示这个字段需要在JSON和实体类之间转换，同时在表对应的类上加上`@TableName(autoResultMap = true)`声明自动映射

### 配置加密

在配置文件中使用明文用户名，密码很不安全，可以使用对称式加密算法AES，使用密钥加密。主要是AES类的`encrypt()`方法用于加密明文

    @Test
    void contextLoads() {
        // 生成 16 位随机 AES 密钥，也可以手动指定
        String randomKey = AES.generateRandomKey();
        System.out.println("randomKey = " + randomKey);

        // 利用密钥对用户名加密
        String username = AES.encrypt("root", randomKey);
        System.out.println("username = " + username);

        // 利用密钥对用户名加密
        String password = AES.encrypt("MySQL123", randomKey);
        System.out.println("password = " + password);

    }

在配置文件中，如果这一项配置项是密钥加密过后的密文，必须加上`mpw:`开头标识

在启动项目是，指定参数--mpw.key=xxxxxx（这里填写密钥），SpringBoot会对配置文件里`mpw:`开头标识的项用该密钥解密拿到实际值

密钥可以自己指定，不能泄露

## 分页插件

MyBatisPlus默认不支持分页，想要分页需要引入插件

    @Configuration
    public class MybatisConfig {

        @Bean
        public MybatisPlusInterceptor mybatisPlusInterceptor() {
            // 初始化核心插件
            MybatisPlusInterceptor interceptor = new MybatisPlusInterceptor();
            // 添加分页插件
            interceptor.addInnerInterceptor(new PaginationInnerInterceptor(DbType.MYSQL));
            return interceptor;
        }
    }

引入分页插件后，IService就有了`page(Page)`，方法，Page是分页参数类，这个方法没有返回值·，查询结果直接注入对应Page类

    Page<User> page = Page.of(pageNo, pageSize); //通过Page.of()构建分页参数类，第一个参数是页号，第二个是页的数据行数
    page.addOrder(OrderItem.asc("balance")); //还支持排序操作，新版本无法new OrderItem，而是使用工厂方法`asc()`，`desc()`
    userService.page(page);

查询后可以用Page的`getRecords()`方法获取List，`getTotal()`获取总条数，`getPages()`获得总页数

对于需要分页查询的数据，一般定义一个PageQuery参数类

    public class PageQuery {
        @ApiModelProperty("页码")
        private Long pageNo;
        @ApiModelProperty("页数量")
        private Long pageSize;
        @ApiModelProperty("排序字段")
        private String sortBy;
        @ApiModelProperty("是否升序")
        private Boolean isAsc;
    }

对于需要查询的请求参数XXXQuery类，直接继承这个类就可以包含分页相关参数

对于分页查询结果，定义对应的PageDTO类

    public class PageDTO<T> {
        @ApiModelProperty("总条数")
        private Long total;
        @ApiModelProperty("总页数")
        private Long pages;
        @ApiModelProperty("集合")
        private List<T> list;
    }

通过Page的三个方法获取对应字段`new PageDTO<UserVO>(page.getTotal(), page.getPages(), page.getRecords())`

其中构建Page参数并查询出结果Page的操作可以封装为PageQuery的工具方法

    public class PageQuery {
        private Integer pageNo;
        private Integer pageSize;
        private String sortBy;
        private Boolean isAsc;

        public <T> Page<T> toMpPage(OrderItem ... orders){
            // 1.分页条件
            Page<T> p = Page.of(pageNo, pageSize);
            // 2.排序条件
            // 2.1.先看前端有没有传排序字段
            if (sortBy != null) {
                p.addOrder(this.isAsc ? OrderItem.asc(this.sortBy) : OrderItem.desc(this.sortBy));
                return p;
            }
            // 2.2.再看有没有手动指定排序字段
            if(orders != null){
                p.addOrder(orders);
            }
            return p;
        }

        public <T> Page<T> toMpPage(String defaultSortBy, boolean isAsc){
            return this.toMpPage(isAsc ? OrderItem.asc(defaultSortBy) : OrderItem.desc(defaultSortBy));
        }

        public <T> Page<T> toMpPageDefaultSortByCreateTimeDesc() {
            return toMpPage(OrderItem.desc(create_time));
        }

        public <T> Page<T> toMpPageDefaultSortByUpdateTimeDesc() {
            return toMpPage(OrderItem.desc(update_time));
        }
    }

把查询的Page结果封装为PageDTO的工程也可以封装为PageDTO的工具方法

    public class PageDTO<V> {
        private Long total;
        private Long pages;
        private List<V> list;

        /**
        * 返回空分页结果
        * @param p MybatisPlus的分页结果
        * @param <V> 目标VO类型
        * @param <P> 原始PO类型
        * @return VO的分页对象
        */
        public static <V, P> PageDTO<V> empty(Page<P> p){
            return new PageDTO<>(p.getTotal(), p.getPages(), Collections.emptyList());
        }

        /**
        * 将MybatisPlus分页结果转为 VO分页结果
        * @param p MybatisPlus的分页结果
        * @param voClass 目标VO类型的字节码
        * @param <V> 目标VO类型
        * @param <P> 原始PO类型
        * @return VO的分页对象
        */
        public static <V, P> PageDTO<V> of(Page<P> p, Class<V> voClass) {
            // 1.非空校验
            List<P> records = p.getRecords();
            if (records == null || records.size() <= 0) {
                // 无数据，返回空结果
                return empty(p);
            }
            // 2.数据转换
            List<V> vos = BeanUtil.copyToList(records, voClass);
            // 3.封装返回
            return new PageDTO<>(p.getTotal(), p.getPages(), vos);
        }

        /**
        * 将MybatisPlus分页结果转为 VO分页结果，允许用户自定义PO到VO的转换方式
        * @param p MybatisPlus的分页结果
        * @param convertor PO到VO的转换函数
        * @param <V> 目标VO类型
        * @param <P> 原始PO类型
        * @return VO的分页对象
        */
        public static <V, P> PageDTO<V> of(Page<P> p, Function<P, V> convertor) { //Function<P,V>，对P应用该Function，转化为V
            // 1.非空校验
            List<P> records = p.getRecords();
            if (records == null || records.size() <= 0) {
                // 无数据，返回空结果
                return empty(p);
            }
            // 2.数据转换
            List<V> vos = records.stream().map(convertor).collect(Collectors.toList());
            // 3.封装返回
            return new PageDTO<>(p.getTotal(), p.getPages(), vos);
        }
    }

封装了工具方法后，分页查询可以简化为

    public PageDTO<UserVO> queryUserByPage(PageQuery query) {
        // 1.构建条件
        Page<User> page = query.toMpPageDefaultSortByCreateTimeDesc(); //PageQuery的工具方法
        // 2.查询
        page(page);
        // 3.封装返回
        return PageDTO.of(page, UserVO.class); //PageDTO的工具方法
    }
