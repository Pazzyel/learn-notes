# EasySpring

## 实现JdbcTemplate

### 配置数据源

连接到数据库就需要配置数据源DataSource

Spring本身只提供了基础的DriverManagerDataSource，但SpringBoot有一个默认配置的数据源采用HikariCP作为连接池。我们仿照Spring Boot的方式，先定义默认的数据源配置项

```yaml
winter:
  datasource:
    url: jdbc:mysql://localhost:3306/winter_db
    diver-class:name: com.mysql.cj.jdbc.Driver
    username: root
    password: xxxxxx
```

然后用一个配置类我们的Hikari数据源注册为Bean

```java
@Configuration
public class JdbcConfiguration {

    //配置默认的Hikari数据源
    @Bean
    public DataSource dataSource(
            @Value("${winter.datasource.url}") String url,
            @Value("${winter.datasource.username}") String username,
            @Value("${winter.datasource.password}") String password,
            @Value("${winter.datasource.driver-class-name}") String driver,
            @Value("${winter.datasource.maximum-pool-size:20}") int maxPoolSize,
            @Value("${winter.datasource.minimum-pool-size:1}") int minPoolSize,
            @Value("${winter.datasource.connection-timeout:30000}") int connectionTimeout
    ) {
        //创建Hikari数据源
        HikariConfig hikariConfig = new HikariConfig();
        hikariConfig.setJdbcUrl(url);
        hikariConfig.setUsername(username);
        hikariConfig.setPassword(password);
        if (driver != null) {
            hikariConfig.setDriverClassName(driver);
        }
        hikariConfig.setMaximumPoolSize(maxPoolSize);
        hikariConfig.setMinimumIdle(minPoolSize);
        hikariConfig.setConnectionTimeout(connectionTimeout);
        return new HikariDataSource(hikariConfig);
    }
}
```

如果这个配置类在客户端包扫描范围下，就直接生效，否则客户端可以通过在启动类上加`@Import`来导入配置

### 编写JdbcTemplate

JdbcTemplate只有DataSource一个依赖

```java
public class JdbcTemplate {
    private final DataSource dataSource;
    
    public JdbcTemplate(final DataSource dataSource) {
        this.dataSource = dataSource;
    }
}
```

JdbcTemplate基于Template设计模式，提供了大量以回调作为参数的模板方法，以execute(ConnectionCallback)为基础

Connection对象表示一个Java客户端到数据库服务器的连接，在这个Connection对象上调用的各种方法其实是对在SQL连接上执行各种方法的封装，通过DataSource的`getConnection()`方法获取到同数据库服务器的一个新的连接

先定义ConnectionCallback

```java
/**
 * 执行连接后的回调方法
 * @param <T>
 */
@FunctionalInterface
public interface ConnectionCallback<T> {
    @Nullable
    T doInConnection(Connection connection) throws SQLException;
}
```

再编写`execute()`方法

```java
public <T> T execute(ConnectionCallback<T> callback) {
    try (Connection connection = dataSource.getConnection()) {
        return callback.doInConnection(connection);
    } catch (SQLException e) {
            throw new DataAccessException(e);
    }
}
```

对于PreparedStatement类型的回调，提供一些方法，其实就是调用上面的`execute()`，传入的参数是一个lambda，回调就是提供连接先生成SQL语句，再调用PreparedStatementCallback的回调方法

```java
/**
 * 通过生成器生成PreparedStatement，并通过回调函数从PreparedStatement执行并返回结果
 * @param creator 预准备的SQL语句生成器
 * @param callback 回调方法
 * @return 回调方法结果
 * @param <T> 结果类型
 */
public <T> T execute(PreparedStatementCreator creator ,PreparedStatementCallback<T> callback) {
    return execute((Connection connection) -> {
        PreparedStatement ps = creator.createPreparedStatement(connection);
        return callback.doInPreparedStatement(ps);
    });
}
```

两个参数的函数式接口定义如下

```java
@FunctionalInterface
public interface PreparedStatementCreator {

    PreparedStatement createPreparedStatement(Connection con) throws SQLException;
}

@FunctionalInterface
public interface PreparedStatementCallback<T> {

    T doInPreparedStatement(PreparedStatement ps) throws SQLException;
}
```

我们可以提供以下方法构造我们需要的`PreparedStatementCreator`，其实就是简单的通过`Connection`的`prepareStatement()`从String的SQL语句生成`PreparedStatement`，再一个个设置参数

```java
/**
 * 生成我们要的生成PreparedStatement的生成器
 * @param sql SQL语句
 * @param params SQL语句的参数
 * @return 生成器
 */
private PreparedStatementCreator createPreparedStatementCreator(String sql, Object... params) {
    return (Connection connection) -> {
        PreparedStatement ps = connection.prepareStatement(sql);
        for (int i = 0; i < params.length; i++) {
            ps.setObject(i + 1, params[i]);
        }
        return ps;
    };
}
```

### 完善JdbcTemplate的各种数据库方法

准备创建PreparedStatementCreator的方法，指定SQL，绑定每个参数

```java
/**
 * 生成我们要的预准备的SQL语句生成器
 * @param sql SQL语句
 * @param params SQL语句的参数
 * @return 生成器
 */
private PreparedStatementCreator createPreparedStatementCreator(String sql, Object... params) {
    return (Connection connection) -> {
        PreparedStatement ps = connection.prepareStatement(sql);
        for (int i = 0; i < params.length; i++) {
            ps.setObject(i + 1, params[i]);
        }
        return ps;
    };
}
```

#### 查询方法

PreparedStatement执行`executeXXX()`查询返回的是`ResultSet`类型，我们必须把它映射成正确Java类的形式

对于基本类型，RowMapper是把ResultSet映射成类型T的mapper，接口定义和基本类型映射的实现如下

```java
/**
 * 把ResultSet映射成T
 * @param <T>
 */
@FunctionalInterface
public interface RowMapper<T> {

    @Nullable
    T mapRow(ResultSet rs, int rowNum) throws SQLException;
}

//ResultSet -> Number 映射
public class NumberRowMapper implements RowMapper<Number> {

    public static final NumberRowMapper INSTANCE = new NumberRowMapper();

    @Nullable
    @Override
    public Number mapRow(ResultSet rs, int rowNum) throws SQLException {
        return (Number) rs.getObject(1);
    }
}

//ResultSet -> Boolean映射
public class BooleanRowMapper implements RowMapper<Boolean> {

    public static final BooleanRowMapper INSTANCE = new BooleanRowMapper();

    @Nullable
    @Override
    public Boolean mapRow(ResultSet rs, int rowNum) throws SQLException {
        return rs.getBoolean(1);
    }
}

//Result -> String 映射
public class StringRowMapper implements RowMapper<String> {

    public static final StringRowMapper INSTANCE = new StringRowMapper();

    @Nullable
    @Override
    public String mapRow(ResultSet rs, int rowNum) throws SQLException {
        return rs.getString(1);
    }
}
```

而如果查询的结果是某个自己定义的Java实体类呢？，我们就需要自己进行转换

将其转换成实体类，我们的mapper，必须能够构造这种实体类，且能够进行字段注入。我们不应该破坏类的封装性，因此只处理public字段和有setter方法的字段，并在mapper保存这些字段

我们先调用，`ResultSet`的`getMetaData()`拿到`ResultSetMetaData`，再通过`ResultSetMetaData`的`getColumnLable(int i)`获取指定下标的属性label，最后`ResultSet`的`getObject(String label)`拿到label对应的值，再注入到对应实体类的属性中

```java
/**
 * 把ResultSet映射成类型T
 * @param <T> 类型
 */
public class BeanRowMapper<T> implements RowMapper<T> {

    private final Class<T> type;
    private final Constructor<T> constructor;
    private final Map<String, Field> fields;
    private final Map<String, Method> setters;

    public BeanRowMapper(Class<T> clazz) {
        Logger logger = LoggerFactory.getLogger(BeanRowMapper.class);
        
        this.type = clazz;
        try {
            this.constructor = clazz.getConstructor();
        } catch (NoSuchMethodException e) {
            throw new DataAccessException(String.format("不能找到要映射成的类%s的默认public构造函数", clazz.getName()));
        }
        this.fields = new HashMap<>();
        this.setters = new HashMap<>();
        //都不可以Declared
        for (Field field : clazz.getFields()) {
            String name = field.getName();
            fields.put(name, field);
            logger.atDebug().log("添加了类{}的字段{}的映射", clazz.getName(), name);
        }
        for (Method method : clazz.getMethods()) {
            if (method.getParameterTypes().length == 1) {
                String name = method.getName();
                //只查找setter方法
                if (name.startsWith("set") && name.length() > 3 && Character.isUpperCase(name.charAt(3))) {
                    name = Character.toLowerCase(name.charAt(3)) + name.substring(4);
                    setters.put(name, method);
                }
                logger.atDebug().log("添加了类{}通过setter方法对字段{}的映射", clazz.getName(), name);
            }
        }
    }

    @Nullable
    @Override
    public T mapRow(ResultSet rs, int rowNum) throws SQLException {
        ResultSetMetaData metaData = rs.getMetaData();
        int columnCount = metaData.getColumnCount();
        try {
            T instance = this.constructor.newInstance();
            for (int i = 1; i <= columnCount; i++) {
                String label = metaData.getColumnLabel(i);
                Method setter = setters.get(label);
                if (setter != null) {
                    //先查找setter方法
                    setter.invoke(instance, rs.getObject(i));
                } else {
                    //如果没有seetr尝试public字段注入
                    Field field = fields.get(label);
                    if (field != null) {
                        field.set(instance, rs.getObject(i));
                    }
                }
            }
            return instance;
        } catch (ReflectiveOperationException e) {
            throw new DataAccessException(String.format("无法映射ResultSet到类%s", type.getSimpleName()),e);
        }
    }
}
```

有了这些转换器就可以写出下列查询方法

```java
/**
 * 查询单个值
 * @param sql SQL语句
 * @param rowMapper 映射器，吧查询到的行映射成Java类
 * @param params 参数
 * @return 单个结果
 * @param <T> 结果的类型
 */
public <T> T queryForObject(String sql, RowMapper<T> rowMapper, Object... params) {
    return execute(createPreparedStatementCreator(sql, params), (PreparedStatement ps) -> {
        T result = null;
        try (ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                if (result == null) {
                    result = rowMapper.mapRow(rs, rs.getRow());
                } else {
                    throw new DataAccessException("单个值查询返回了多个行");
                }
            }
        }
        //这里的抛出的异常是错误，应该允许查询返回null
//      if (result == null) {
//          throw new DataAccessException("没有任何有效值返回");
//      }
        return result;
    });
}

/**
 * 查询单个值，自动把类型处理成映射器
 * @param sql SQL语句
 * @param type 结果的类型
 * @param params 参数
 * @return 查询单个值的结果
 * @param <T> 类型
 */
public <T> T queryForObject(String sql, Class<T> type, Object... params) {
    if (Number.class.isAssignableFrom(type)) {
        return (T) queryForObject(sql, NumberRowMapper.INSTANCE, params);
    }
    if (Boolean.class == type) {
        return (T) queryForObject(sql, BooleanRowMapper.INSTANCE, params);
    }
    if (String.class == type) {
        return (T) queryForObject(sql, StringRowMapper.INSTANCE, params);
    }
    return queryForObject(sql, new BeanRowMapper<>(type), params);
}

/**
 * 查询单个数字
 * @param sql SQL语句
 * @param params 参数
 * @return 数字
 */
public Number queryForNumber(String sql, Object... params) {
    return queryForObject(sql, NumberRowMapper.INSTANCE, params);
}

/**
 * 列表查询
 * @param sql SQL语句
 * @param mapper 映射器，吧查询到的行映射成Java类
 * @param params 参数
 * @return List
 * @param <T> List的类型
 */
public <T> List<T> queryForList(String sql, RowMapper<T> mapper, Object... params) {
    return execute(createPreparedStatementCreator(sql, params), (PreparedStatement ps) -> {
        ResultSet rs = ps.executeQuery();
        List<T> result = new ArrayList<>();
        while (rs.next()) {
            result.add(mapper.mapRow(rs, rs.getRow()));
        }
        return result;
    });
}

/**
 * 列表查询，自动把类型处理成映射器
 * @param sql SQL语句
 * @param type 结果的类型
 * @param params 参数
 * @return List
 * @param <T> List的类型
 */
public <T> List<T> queryForList(String sql, Class<T> type, Object... params) {
    if (Number.class.isAssignableFrom(type)) {
        return (List<T>) queryForList(sql, NumberRowMapper.INSTANCE, params);
    }
    if (Boolean.class == type) {
        return (List<T>) queryForList(sql, BooleanRowMapper.INSTANCE, params);
    }
    if (String.class == type) {
        return (List<T>) queryForList(sql, StringRowMapper.INSTANCE, params);
    }
    return queryForList(sql, new BeanRowMapper<>(type), params);
}
```

#### 更改（增删改）

更改指的是会对表产生影响的行为，因此不限于更新

```java
/**
 * SQL更改语句
 * @param sql SQL语句
 * @param params 参数
 * @return 更改的行数
 */
public int update(String sql, Object... params) {
    return execute(createPreparedStatementCreator(sql,params), PreparedStatement::executeUpdate);
}

/**
 * SQL更改语句，使用返回主键
 * @param sql SQL语句
 * @param params 参数
 * @return 主键
 */
public Number updateAndReturnGeneratedKey(String sql, Object... params) {
    return execute(createPreparedStatementCreatorUsingGeneratedKey(sql,params), (PreparedStatement ps) -> {
        int n = ps.executeUpdate();
        if (n == 0) {
            throw new DataAccessException("无法返回主键，没有任何新的行被插入");
        }
        if (n > 1) {
            throw new DataAccessException("无法返回主键，有多个行被插入");
        }
        try (ResultSet keys = ps.getGeneratedKeys()) {
            while (keys.next()) {
                return (Number) keys.getObject(1);
            }
        }
        throw new DataAccessException("发生错误，到达了不应到达的语句");
    });
}
```

## 实现事务

定义事务注解，和Spring不同，我们这里的注解只允许在类上定义，这样只需要在对应的`BeanPostProcessor`中检查对应Bean实例上的注解即可，如果允许在方法上注解，就需要遍历Bean实例的所有方法并检查注解

```java
@Target(value = ElementType.TYPE)
@Retention(value = RetentionPolicy.RUNTIME)
@Documented
@Inherited
public @interface Transactional{
    String value() default "platformTransactionManager";
}
```

注解的默认值`platformTransactionManager`表示用名字为platformTransactionManager的代理类Bean来管理事务，因此我们创建对应接口

```java
public interface PlatformTransactionManager {
}
```

定义`TransactionStatus`，表示当前事务状态

```java
public class TransactionStatus {
    private final Connection connection;
    
    public TransactionStatus(Connection connection) {
        this.connection = connection;
    }
}
```

最后定义我们进行事务操作的核心类，它是实际进行事务管理的类，由于我们的`@Transactional`注解配置的Handler名称默认是`platformTransactionManager`，因此其必须实现`PlatformTransactionManager`接口，并以`platformTransactionManager`的名字注册到IoC容器作为事务的代理类Bean，这样才能在AOP的调用中和找到拦截器和原始Bean实例结合生成代理类

```java
public class DataSourceTransactionManager implements PlatformTransactionManager, InvocationHandler {

    public static final ThreadLocal<TransactionStatus> transactionStatus = new ThreadLocal<>();
    private final DataSource dataSource;

    public DataSourceTransactionManager(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /**
     * 事务注解的Handler，拦截事务方法并进行AOP
     * @return 方法返回结果
     * @throws Throwable SQL操作的异常
     */
    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        TransactionStatus status = transactionStatus.get();
        if (status == null) {
            try (Connection connection = dataSource.getConnection()) {
                boolean autoCommit = connection.getAutoCommit();
                if (autoCommit) {
                    //关闭自动事务提交
                    connection.setAutoCommit(false);
                }
                try {
                    transactionStatus.set(new TransactionStatus(connection));
                    Object result = method.invoke(proxy, args);
                    //手动在业务方法完成后才提交事务
                    connection.commit();
                    return result;
                } catch (InvocationTargetException e) {
                    //发生异常回滚事务
                    TransactionException transactionException = new TransactionException(e.getCause());
                    try {
                        //尝试回滚事务
                        connection.rollback();
                    } catch (SQLException sqlException) {
                        transactionException.addSuppressed(sqlException);
                    }
                    throw transactionException;
                } finally {
                    //收尾工作，清除ThreadLocal，恢复事务自动提交
                    transactionStatus.remove();
                    if (autoCommit) {
                        connection.setAutoCommit(true);
                    }
                }
            }
        } else {
            //当前方法已经包含在事务，无需拦截
            return method.invoke(proxy, args);
        }
    }
}
```

其中方法调用抛出的异常`InvocationTargetException`是反射方法`invoke()`执行时的包装异常，使用`getCause()`方法获取原始异常，这里我们的注解没有`rollbackFor`属性，因此只要有异常就直接回滚

我们通过`ThreadLocal`保存当前的事务状态，因为是一个线程只能同时执行一个事务，如果其不是null，说明当前正在执行一个事务，就不需要拦截方法

这样就够了吗？当然不是！JDBC的事务是依赖数据库事务进行的，而数据库的事务是对于一个Connection而言的，不同的Connection根本无法存在于同一个事务。而我们之前的`JdbcTemplate`的核心方法如下

```java
public <T> T execute(ConnectionCallback<T> callback) {
    try (Connection connection = dataSource.getConnection()) {
        return callback.doInConnection(connection);
    } catch (SQLException e) {
        throw new DataAccessException(e);
    }
}
```

每一次执行一次SQL操作都会创建一个新的Connection！每个JDBC调用都有自己单独的Connection，显然无法完成事务，虽然前面的if判断会走else的逻辑直接执行SQL，但由于是一个单独的Connection，执行完马上就提交了，没有起到事务作用

显然，我们必须改造`JdbcTemplate`的核心方法`execute()`，我们可以创建一个`TransactionalUtils`类用于获取当前线程的`TransactionStatus`信息

```java
public class TransactionalUtils {

    /**
     * 获取当前线程的事务连接
     * @return 事务Connection对象，没有事务时返回null
     */
    @Nullable
    public static Connection getCurrentConnection() {
        TransactionStatus transactionStatus = DataSourceTransactionManager.transactionStatus.get();
        return transactionStatus == null ? null : transactionStatus.getConnection();
    }
}
```

再改造`JdbcTemplate`的核心方法`execute()`

```java
/**
 * JDBC核心方法，其它的所有方法最后都调用此方法，建立连接后进行回调
 * @param callback 回调方法
 * @return 回调方法结果
 * @param <T> 结果类型
 */
public <T> T execute(ConnectionCallback<T> callback) {
    Connection currentConnection = TransactionalUtils.getCurrentConnection();
    if (currentConnection != null) {
        //当前存在事务，直接使用事务的connection
        try {
            return callback.doInConnection(currentConnection);
        } catch (SQLException e) {
            throw new DataAccessException(e);
        }
    } else {
        //当前不存在事务，新建一个连接
        try (Connection connection = dataSource.getConnection()) {
            return callback.doInConnection(connection);
        } catch (SQLException e) {
            throw new DataAccessException(e);
        }
    }
}
```

最后还需要提供BeanPostProcessor，让IoC创建`@Transactional`的Bean时使用代理类替换，这里直接使用我们在AOP环节定义的`AnnotationProxyBeanPostProcessor`

```java
public class TransactionalBeanPostProcessor extends AnnotationProxyBeanPostProcessor<Transactional> {
}
```

记得在我们之前的JdbcConfiguration上注册以下Bean，这样用户只需要在启动类`@Import(JdbcConfiguration.calss)`，就可以直接使用JdbcTemplate

```java
@Bean
public JdbcTemplate jdbcTemplate(@Autowired DataSource dataSource) {
    return new JdbcTemplate(dataSource);
}

@Bean
public TransactionalBeanPostProcessor transactionalBeanPostProcessor() {
    return new TransactionalBeanPostProcessor();
}

@Bean
public PlatformTransactionManager platformTransactionManager(@Autowired DataSource dataSource) {
    return new DataSourceTransactionManager(dataSource);
}
```

## 目前存在的问题

当前BeanRowMapper的实现比较简陋

- `JdbcTemplate`的`public Number updateAndReturnGeneratedKey(String sql, Object... params)`方法返回的其实是`BigDecimal`，转换成`Long`，`Integer`等需要手动调用`Number`的`longValue()`，`intValue()`方法。不过Spring JDBC本身也是这样做的（`KeyHolder`的`getKey()`方法返回Number），将`Number`类型自动转换成实际的id类型事实上是MyBatis等框架提供的功能

- MySQL驱动默认从数据库bigint类型查出来的数据会被映射成`Long`，`BeanRowMapper`，在注入属性时只是简单的反射调用，如果类型是基本类型会报错，因为反射不会自动拆/装箱

解决方法，先判断要注入的属性是不是基本类型，如果是就先手动拆箱，由于Java的基本类型不能使用泛型，需要写所有基本类型的if

```java
/**
    * 原始类型直接反射注入包装类会出错，针对原始类型的setter注入
    * @param setter setter方法
    * @param instance 类实例
    * @param rs 查询结果
    * @param i 查询结果索引
    * @throws SQLException 转换查询结果异常
    */
private void invokePrimitive(Method setter, Object instance, ResultSet rs, int i) throws SQLException {
    //只执行带一个参数的setter
    if (setter.getParameterTypes().length != 1) {
        return;
    }
    Class<?> paramType = setter.getParameterTypes()[0];
    //只执行参数是原始类型的setter
    if (!paramType.isPrimitive()) {
        return;
    }
    try {
        if (paramType == byte.class) {
            setter.invoke(instance, rs.getByte(i));
        }
        if (paramType == short.class) {
            setter.invoke(instance, rs.getShort(i));
        }
        if (paramType == int.class) {
            setter.invoke(instance, rs.getInt(i));
        }
        if (paramType == long.class) {
            setter.invoke(instance, rs.getLong(i));
        }
        if (paramType == boolean.class) {
            setter.invoke(instance, rs.getBoolean(i));
        }
        if (paramType == double.class) {
            setter.invoke(instance, rs.getDouble(i));
        }
        if (paramType == float.class) {
            setter.invoke(instance, rs.getFloat(i));
        }
    } catch (InvocationTargetException | IllegalAccessException e) {
        throw new ClassCastException(e.getMessage());
    }
}

/**
    * 原始类型直接反射注入包装类会出错，针对原始类型的字段注入
    * @param field 字段
    * @param instance 类实例
    * @param rs 查询结果
    * @param i 查询结果索引
    * @throws SQLException 转换查询结果异常
    */
private void invokePrimitive(Field field, Object instance, ResultSet rs, int i) throws SQLException {
    Class<?> fieldType = field.getType();
    if (!fieldType.isPrimitive()) {
        return;
    }
    try {
        if (fieldType == byte.class) {
            field.set(instance,rs.getByte(i));
        }
        if (fieldType == short.class) {
            field.set(instance,rs.getShort(i));
        }
        if (fieldType == int.class) {
            field.set(instance,rs.getInt(i));
        }
        if (fieldType == long.class) {
            field.set(instance,rs.getLong(i));
        }
        if (fieldType == boolean.class) {
            field.set(instance,rs.getBoolean(i));
        }
        if (fieldType == double.class) {
            field.set(instance,rs.getDouble(i));
        }
        if (fieldType == float.class) {
            field.set(instance,rs.getFloat(i));
        }
    } catch (IllegalAccessException e) {
        throw new ClassCastException(e.getMessage());
    }
}
```

在`mapRow()`方法先判断要注入的是不是基本类型，是就调用上面的方法

```java
@Nullable
@Override
public T mapRow(ResultSet rs, int rowNum) throws SQLException {
    ...
    try {
        T instance = this.constructor.newInstance();
        for (int i = 1; i <= columnCount; i++) {
            ...
            if (setter != null) {
                //先查找setter方法
                if (setter.getParameterTypes()[0].isPrimitive()) {
                    invokePrimitive(setter,instance,rs,i);
                } else {
                    setter.invoke(instance, rs.getObject(i));
                }
            } else {
                //如果没有setter尝试public字段注入
                Field field = fields.get(label);
                if (field != null) {
                    if (field.getType().isPrimitive()) {
                        invokePrimitive(field,instance,rs,i);
                    } else {
                        field.set(instance, rs.getObject(i));
                    }
                }
            }
        }
        return instance;
    } catch (ReflectiveOperationException e) {
        throw new DataAccessException(String.format("无法映射ResultSet到类%s", type.getSimpleName()),e);
    }
}
```

- `@Transactional`如果想要注解在方法上怎么办？

我们在AOP部分定义的`AnnotationProxyBeanPostProcessor`只能扫描到类层面的注解，不能扫描到方法层面，不足以满足我们的要求：`@Transactional`在类或者方法上都要生成代理类，因此我们定义一个新的`AnnotationClassAndMethodProxyBeanPostProcessor`，大部分逻辑从`AnnotationProxyBeanPostProcessor`复制即可（也可以继承，但是我们之前把父类的属性设置为private了，继承还要修改为protected，要侵入原来的代码），只需要修改其中的`postProcessBeforeInitialization()`方法，添加先查找类，再查找方法上的注解的逻辑

```java
public class AnnotationClassAndMethodProxyBeanPostProcessor<A extends Annotation> implements BeanPostProcessor {

    ...

    @Override
    public Object postProcessBeforeInitialization(Object bean, String beanName) {
        //获取注解，先查类
        A around = bean.getClass().getAnnotation(annotationType);
        //类上没有，查找方法
        if (around == null) {
            for (Method method : bean.getClass().getMethods()) {
                if (method.isAnnotationPresent(annotationType)) {
                    around = method.getAnnotation(annotationType);
                    break;
                }
            }
        }

        ...
    }

    ...
}
```
