# EasySpring

Spring虽然初始号称轻量级框架，但如今已经变得大而全，和轻量级谈不上沾边

事实上Spring提供的丰富功能有很大一部分是我们很少用到的，通过学习Spring的原理，就可以构建一个更轻量的，能够满足我们基础要求的Spring

## IoC容器

Spring的IoC容器分为两类

- BeanFactory，延迟创建Bean
- ApplicationContext，在启动时立刻创建Bean

大多数情况使用ApplicationContext，因此我们只详细探究其实现

Spring早期Bean管理只使用xml文件配置，但后续又加入了注解配置，尤其是SpringBoot出现后大部分项目都使用了更方便的注解配置，虽然Spring依然保留了xml配置但是大部分情况都不使用，因此我们只详细探究注解配置的实现

Spring的Bean有Singleton类型的Bean和Prototype类型的Bean，几乎所有情况都使用Singleton类型的Bean

Spring的其他功能，例如，层级容器、MessageSource、一个Bean允许多个名字等功能，平时用的也比较少

### 包扫描和Bean注册

要完成Bean的注册，就需要解决扫描某个包的类并根据注解实例化Bean的问题，分为这几部

1. 获取所有在我们指定的包下的资源路径，包括file和jar
2. 扫描资源路径下的所有class和jar文件
3. 把这些文件的路径和带有包名的全限定名保存备用

首先解决包扫描，也就是@ComponentScan，@SpringBootApplication默认扫描启动类所在目录

在目录下搜索类，就必须搜索这个目录的所有.class文件

进行文件的抽象，一个文件通常以路径+名字表示，我们可以用Java16的新特性record表示

record用于定义只保存数据的类，record类名后面的()里写上成员变量，自动生成equals()等样板代码

```java
public record Resource(String path, String name) {
}
```

这里的目的是把资源的URI转换成文件路径+包名（/分割）的形式，path是路径，name是包名

例如

```path
file:C:/workspace/project/target/classes/com/example/demo/Hello.class ->

file:C:/workspace/project/target/classes/com/example/demo/Hello.class  + com/example/demo/Hello.class

jar:file:/C:/maven/repo/example-lib-1.0.jar!/com/example/demo/Hello.class ->

jar:file:/C:/maven/repo/example-lib-1.0.jar + com/example/demo/Hello.class
```

通过`Thread.currentThread().getContextClassLoader().getResources(basePackagePath);`获取包的资源路径的URL/URI，它的形式一般是`file:C:/workspace/project/target/classes/com/example/demo`或者`jar:file:/C:/maven/repo/example-lib-1.0.jar!/com/example/demo`

用`Paths.get()`把它转化成Path后再用`Files.walk()`来遍历这个包下可能的文件并且切分路径

先获取去到包路径的基础路径，通过在URI中去掉最后的包路径就保留了基础路径uriBaseString，即为`file:C:/workspace/project/target/classes`或者`jar:file:/C:/maven/repo/example-lib-1.0.jar`

file:的定位路径就是`Files.walk()`扫描出来的file的路径，去掉前面我们获取的基础路径就是class文件从包开始的相对路径，也就是我们要的name，如`com/example/demo/Hello.class`

jar:的定位路径就是uriBaseString，`Files.walk()`扫描jar出现的路径是class文件在jar的内部路径，也就是包的相对路径，例如`/com/example/demo/Hello.class`这就是我们要的name

实际编写注意去除结尾，开头的/

在ResourceResolver完成以下方法

```java
//扫描包名下的所有类，通过映射把这个文件转换成我们想要的R
public <R> List<R> scan(Function<Resource,R> mapper) {
    //把包名转化成路名名
    String basePackagePath = this.basePackage.replace('.', '/');
    List<R> container = new ArrayList<>();
    try {
        logger.atDebug().log("Scan path: " + basePackagePath);
        //加载所有包含这个包的资源的URL,可能是包的绝对路径，也可能是JAR的内部路径
        Enumeration<URL> resources = Thread.currentThread().getContextClassLoader().getResources(basePackagePath);
        while (resources.hasMoreElements()) {
            //uri案例：file:C:/workspace/project/target/classes/com/example/demo/
            URI uri = resources.nextElement().toURI();
            String uriString = URLDecoder.decode(uri.toString(), StandardCharsets.UTF_8);
            uriString = removeEndSlash(uriString);

            //资源去掉包名的绝对路径，案例：file:C:/workspace/project/target/classes/
            //对于file,为的是到时候再文件路径去掉这一部分得到相对路径。
            //对于jar,其uri后面本来就跟着包名，jar文件的路径在包名前面，要去掉
            String uriBaseString = uriString.substring(0, uriString.length() - basePackage.length());
            uriBaseString = removeEndSlash(uriBaseString);

            if (uriBaseString.startsWith("file:")) {
                //是文件资源，Path对象可以通过Paths工具类从uri获取，是uri下的一个路径对象
                scanFile(false, uriBaseString, Paths.get(uri), mapper, container);
            } else if (uriBaseString.startsWith("jar:")) {
                FileSystem fs = FileSystems.newFileSystem(uri, Map.of());
                //是JAR资源
                scanFile(true, uriBaseString, fs.getPath(uriBaseString), mapper, container);
                fs.close();//记得关闭资源
            }
        }
    } catch (IOException e) {
        throw new UncheckedIOException(e);
    } catch (URISyntaxException e) {
        throw new RuntimeException(e);
    }
    return container;
}

private <R> void scanFile(boolean isJAR, String uriBaseString ,Path path, Function<Resource,R> mapper, List<R> container) throws IOException {
    //先前传入的方法保证以file:或jar:开头绝对路径basePath已经没有/结尾，为了安全再检查一次
    String basePath = removeEndSlash(uriBaseString);
    Files.walk(path).filter(Files::isRegularFile).forEach(file -> {
        Resource resource;
        if (isJAR) {
            //这里basePath是JAR文件（jar:)的绝对路径（去掉包名），file.toString()是JAR内部的路径，相当于以/开头的包路径
            resource = new Resource(basePath, removeStartSlash(file.toString()));
        } else {
            String resourcePath = file.toString();
            //这里资源路径截取了去掉file:开头后绝对路径的长度，剩余的长度就是以/开头的包路径，去掉开头/
            String name = resourcePath.substring(basePath.substring("file:".length()).length());
            resource = new Resource("file:" + resourcePath, removeStartSlash(name));
        }
        R result = mapper.apply(resource);
        logger.atDebug().log("Scan result: " + result);
        if (result != null) {
            container.add(result);
        }
    });
}

//如果有，移除路径末尾的空格，Windows上是\\
private String removeEndSlash(String path) {
    if (path.endsWith("/") || path.endsWith("\\")) {
        path = path.substring(0, path.length() - 1);
    }
    return path;
}

//如果有，移除路径开头的空格，Windows上是\\
private String removeStartSlash(String path) {
    if (path.startsWith("/") || path.startsWith("\\")) {
        path = path.substring(1);
    }
    return path;
}
```

### 配置文件配置项注入@Value的实现

要实现@Vaule，我们需要做这几件事情

1. 通过反射获取拥有@Value的类的对应字段并获取@Value的内容
2. 解析@Value的内容，并从配置文件等地方读取这个内容的实际值
3. 通过反射把实际值注入这个字段

这里我们讨论最复杂的第2部解析@Value的内容

#### String类型的配置查询

能够在@Value中的通常是${xxx}或者${xxx:xxx}的格式

定义PropertyResolver，支持几种方法查询配置项

- 按配置的key查询，例如：getProperty("app.title");
- 以${abc.xyz}形式的查询，例如，`getProperty("${app.title}")`，常用于`@Value("${app.title}")`注入；
- 带默认值的，以${abc.xyz:defaultValue}形式的查询

Java本身提供了按key-value查询的Properties，其的内容是我们在application.properties配置的内容。我们在构造是保存系统变量和Properties，并提供对应方法查询

```java
Map<String,String> properties = new HashMap<>();

public PropertyResolver(Properties props) {
    //存入环境变量
    properties.putAll(System.getenv());
    //存入传入的配置参数
    Set<String> keys = props.stringPropertyNames();
    for (String key : keys) {
        properties.put(key, props.getProperty(key));
    }
}

@Nullable
public String getProperty(String key) {
    return properties.get(key);
}
```

加上解析${xxx:xxx}形式的key

```java
public Property parseProperty(String key) {
    if (key.startsWith("${") && key.endsWith("}")) {
        int index = key.indexOf(":");
        if (index == -1) {
            return new Property(key.substring(2, key.length() - 1), null);
        } else {
            return new Property(key.substring(2, index), key.substring(index + 1, key.length() - 1));
        }
    }
    return null;
}
```

修改我们的·getProperty()`方法使之能支持三种形式的key

```java
@Nullable
public String getProperty(String key) {
    Property property = parseProperty(key);
    if (property != null) {
        //是${}的形式
        String defaultValue = property.defaultValue();
        if (defaultValue != null) {
            return getProperty(property.key(), defaultValue);
        } else {
            return getNotNullValue(property.key());
        }
    }
    //是去掉${}的形式
    return properties.get(key);
}

//获取带有默认值的配置，key一定是不带${}的形式
private String getProperty(String realKey, String defaultValue) {
    String value = properties.getOrDefault(realKey, defaultValue);
    return parseValue(value);
}

//对于没有默认值的${}，必须取出不是null的value
private String getNotNullValue(String key) {
    String value = getProperty(key);
    return Objects.requireNonNull(value, "Missing required property: " + key);
}
```

其中`parseValue()`是对${}解析出来的值的嵌套解析，因为值也有可能是另一个嵌套的key，因此经过`parseValue()`的value才能保证是解析出来的最终value

```java
//value可能是真正的value，也可能是嵌套的带${}的形式的key
private String parseValue(String value) {
    Property parsedValue = parseProperty(value);
    if (parsedValue != null) {
        //是${}的形式
        String defaultValue = parsedValue.defaultValue();
        if (defaultValue != null) {
            return getProperty(parsedValue.key(), defaultValue);
        } else {
            return getNotNullValue(parsedValue.key());
        }
    } else {
        //是真正的value
        return value;
    }
}
```

在Spring中，${}的key之间还可以组合，实现比较麻烦，这里暂时不做

#### 实现注入的自动类型转换

上面的介绍只探究了如何获取指定配置项目的String过程

@Value注入时，允许boolean、int、Long等基本类型和包装类型。此外，Spring还支持Date、Duration等类型的注入，把String按照格式解析成对应类

先用一个Map储存所有String -> 待转换类型的映射并设置常用类型转换，记得在构造函数调用这个方法

```java
private final Map<Class<?>,Function<String,Object>> converters = new HashMap<>();

private void setAllConverters() {
    //设置所有基本类型映射
    converters.put(byte.class,Byte::parseByte);
    converters.put(Byte.class, Byte::parseByte);
    converters.put(short.class,Short::parseShort);
    converters.put(Short.class, Short::parseShort);
    converters.put(int.class,Integer::parseInt);
    converters.put(Integer.class, Integer::parseInt);
    converters.put(long.class,Long::parseLong);
    converters.put(Long.class, Long::parseLong);
    converters.put(float.class,Float::parseFloat);
    converters.put(Float.class, Float::parseFloat);
    converters.put(double.class,Double::parseDouble);
    converters.put(Double.class, Double::parseDouble);
    converters.put(boolean.class,Boolean::parseBoolean);
    converters.put(Boolean.class, Boolean::parseBoolean);
    converters.put(String.class, s -> s);
    //设置时间日期地点类映射
    converters.put(LocalDate.class, LocalDate::parse);
    converters.put(LocalTime.class, LocalTime::parse);
    converters.put(LocalDateTime.class, LocalDateTime::parse);
    converters.put(ZonedDateTime.class, ZonedDateTime::parse);
    converters.put(Duration.class, Duration::parse);
    converters.put(ZoneId.class, ZoneId::of);
}
```

还可以定义`registerConverter()`的public方法让用户自定义转换

```java
//为用户提供自定义类型转换接口
public void registerConverter(Class<?> clazz, Function<String,Object> converter) {
    converters.put(clazz,converter);
}
```

#### 读取yaml配置文件

SpringBoot有了对yaml配置文件的支持，yaml配置文件被组织成一个树形结构，可以用snakeyaml读取

```xml
<dependency>
    <groupId>org.yaml</groupId>
    <artifactId>snakeyaml</artifactId>
    <version>2.0</version>
</dependency>
```

通过Yaml的load方法从InputStream读取出yaml的配置，读取的结果是树形结构，Map的value会嵌套Map

在YamlUtils定义以下方法

```java
//把yaml转换成Map<String,Object>注意其为树形结构
public static Map<String,Object> loadYaml(String path){
    LoaderOptions loaderOptions = new LoaderOptions();
    DumperOptions dumperOptions = new DumperOptions();
    Representer representer = new Representer(dumperOptions);
    NoImplicitResolver resolver = new NoImplicitResolver();
    Yaml yaml = new Yaml(new Constructor(loaderOptions), representer, dumperOptions, loaderOptions, resolver);
    return ClassPathUtils.readInputStream(path, stream -> (Map<String, Object>) yaml.load(stream));
}
```

其中`ClassPathUtils.readInputStream()`其实就是把path下的resources目录读取为输入流

```java
/**
* 用于查找指定路径下resource的输入流并对齐执行callback方法
* @param path 查找路径
* @param callback 对输入流的回调方法
* @return callback的返回结果
* @param <T> callback的返回类型
*/
public static <T> T readInputStream(String path, InputStreamCallback<T> callback) {
    //移除开头的/
    if (path.startsWith("/")) {
        path = path.substring(1);
    }
    //对path路径下的输入流执行callback
    try (InputStream stream = ClassPathUtils.getContextClassLoader().getResourceAsStream(path)) {
        if (stream == null) {
            throw new FileNotFoundException("File not found: " + path);
        }
        return callback.doWithInputStream(stream);
    } catch (IOException e) {
        e.printStackTrace();
        throw new UncheckedIOException(e);
    }

}
```

由于我们先前的设计是针对properties文件的扁平结构的，因此我们要把树形结构的map转化成properties的扁平结构形式，可以递归每层Map，传入上一级key的前缀来构造

在YamlUtils定义以下方法

```java
/**
* 把树形Map转换成扁平Map
* @param source 树形Map
* @param prefix 递归转换中先前key的前缀，一定以.结尾
* @param target 扁平Map
*/
private static void convertTreeToPlainMap(Map<String,Object> source, String prefix, Map<String,Object> target) {
    for (String key : source.keySet()) {
        Object value = source.get(key);
        if (value instanceof Map) {
            Map<String,Object> map = (Map<String,Object>) value;
            convertTreeToPlainMap(map, prefix + key + ".", target);
        } else if (value instanceof List) {
            ((List<?>) value).forEach(e -> target.put(prefix + key,e));
        } else {
            target.put(prefix + key, value.toString());//SnakeYaml默认会自动转换int、boolean等value，需要手动把value均按String类型返回
        }
    }
}

//把yaml转换成扁平Map<String,Object>
public static Map<String,Object> loadPlainYaml(String path){
    Map<String,Object> treeYaml = loadYaml(path);
    //扁平结构的Map可能有重复的键，必须用LinkedHashMap
    Map<String,Object> plainYaml = new LinkedHashMap<>();
    convertTreeToPlainMap(treeYaml,"",plainYaml);
    return plainYaml;
}
```

### 实现IoC容器

#### 注册Bean到Map<String,BeanDefinition>

IoC容器的实现，就是把@ComponentScan的范围所有@Component和@Bean加载到内存并可以随时被使用

1. 定义对应的保存Bean的数据结构，这个结构应该提供通过某种方式（名称，类型）获取Bean的功能
2. 找到@ComponentScan下所有@Component和@Bean所注册的Bean，放入我们定义的结构

Spring事实上就是用一个HashMap（或ConcurrentHashMap）来保存bean信息的，很容易能想到用bean的名字作为Map的key，bean的示例作为value，但是单纯的Bean的示实例并不包含足够多信息，因此我们定义一个BeanDefinition作为value

Spring允许一个bean有多个名字，这里我们简化这个功能，一个bean只允许有一个不冲突的名字

```java
public class BeanDefinition implements Comparable<BeanDefinition> {
    // 全局唯一的Bean Name:
    public String name;

    // Bean的声明类型:
    public Class<?> beanClass;

    // Bean的实例:
    public Object instance = null;

    // 构造方法/null:
    public Constructor<?> constructor;

    // 工厂方法名称/null:
    public String factoryName;

    // 工厂方法/null:
    public Method factoryMethod;

    // Bean的顺序:
    public int order;

    // 是否标识@Primary:
    public boolean primary;

    // init/destroy方法名称:
    public String initMethodName;
    public String destroyMethodName;

    // init/destroy方法:
    public Method initMethod;
    public Method destroyMethod;

    //构造函数形式构造，用于@Component，采用此方法构造的BeanDefinition的factoryName和factoryMethod是null
    public BeanDefinition(String name, Class<?> beanClass, Constructor<?> constructor, int order, boolean primary, String initMethodName, String destroyMethodName, Method initMethod, Method destroyMethod) {
        this.name = name;
        this.beanClass = beanClass;
        this.constructor = constructor;
        this.factoryName = null;
        this.factoryMethod = null;
        this.order = order;
        this.primary = primary;
        if (this.constructor != null) {
            this.constructor.setAccessible(true);
        }
        setIntiAndDestroyMethod(initMethodName, initMethod, destroyMethodName, destroyMethod);
    }

    //工厂方法形式构造，用于@Bean，采用此方法构造的BeanDefinition的Constructor是null
    public BeanDefinition(String name, Class<?> beanClass, String factoryName, Method factoryMethod, int order, boolean primary, String initMethodName, String destroyMethodName, Method initMethod, Method destroyMethod) {
        this.name = name;
        this.beanClass = beanClass;
        this.constructor = null;
        this.factoryName = factoryName;
        this.factoryMethod = factoryMethod;
        this.order = order;
        this.primary = primary;
        this.factoryMethod.setAccessible(true);
        setIntiAndDestroyMethod(initMethodName, initMethod, destroyMethodName, destroyMethod);
    }

    //获取非空实例
    @NotNull
    public Object getRequiredInstance() {
        if (this.instance == null) {
            throw new BeanCreationException(String.format("名称为 %s 的Bean在当前节点的实例暂未被实例化", this.getName()));
        }
        return this.instance;
    }

    public void setInstance(Object instance) {
        this.instance = instance;
    }

    private void setIntiAndDestroyMethod(String initMethodName, Method initMethod, String destroyMethodName, Method destroyMethod) {
        this.initMethodName = initMethodName;
        this.destroyMethodName = destroyMethodName;
        if (initMethod != null) {
            initMethod.setAccessible(true);
        }
        if (destroyMethod != null) {
            destroyMethod.setAccessible(true);
        }
        this.initMethod = initMethod;
        this.destroyMethod = destroyMethod;
    }

    @Override
    public int compareTo(@NotNull BeanDefinition o) {
        //先排Order
        int compare = this.getOrder() - o.getOrder();
        //Order一致就根据名字排序
        if (compare == 0) {
            compare = this.getName().compareTo(o.getName());
        }
        return compare;
    }
}
```

对于自己定义的带@Component注解的Bean，我们需要获取Class类型，获取构造方法来创建Bean，然后收集@PostConstruct和@PreDestroy标注的初始化与销毁的方法，以及其他信息，如@Order定义Bean的内部排序顺序，@Primary定义存在多个相同类型时返回哪个“主要”Bean

对于从@Configuration导入的@Bean，我们把它看作Bean的工厂方法，我们需要获取方法返回值作为Class类型，方法本身作为创建Bean的factoryMethod，然后收集@Bean定义的initMethod和destroyMethod标识的初始化于销毁的方法名，以及其他@Order、@Primary等信息

对应声明类型，叫这个名字是因为获取到的类型不一定是示例的类型

- @Component定义的Bean，它的声明类型就是其Class本身
- @Bean工厂方法创建的Bean，实际类型可能是某个子类

我们这里只存储声明类型，实际类型可以通过instance.getClass()获得

根据名字匹配bean，由于我们的规定，名字唯一，可以从Map<String,BeanDefinition>拿到Bean

根据类型匹配bean，因为一个类型可以有很多个Bean，我们必须遍历找到所有符合这个类型的Bean，如果只有一个就之间选择这个Bean，有多个时，如果有其中一个指定了@Primary就选择这个，否则应该报错，因为不知道哪个是合适的Bean

接下来就是找到所有Bean放入我们的结构

1. 拿到@ComponentScan的信息，扫描配置的包下所有Class并返回名字String，注意还要包含@Import导入的class
2. 根据Bean的名字，完成BeanDefinition的创建，注意除了@Component，@Configuiration下的@Bean注解的方法也要注册成Bean

首先就是找到被@ComponentScan注解的地方，我们可以定义一个工具方法，用于查找指定类下的特定注解，注意的是注解本身还有可能被其它注解所注解，为了支持嵌套注解我们也必须递归查找所有的非目标注解

例外的是在包`java.lang.annotation`的注解可以不递归查找，因为它们不可能携带业务信息

在ClassUtils下定义方法

```java
public static <A extends Annotation> A findAnnotation(Class<?> target, Class<A> annotationClass) {
    //直接查询目标注解
    A annotation = target.getAnnotation(annotationClass);
    for (Annotation a : target.getAnnotations()) {
        //获取注解的反射Class不准用getClass()，那个是接口
        //注解会被动态代理出一个实现类，我们要拿到实现类Class必须用annotationType()
        Class<?> aType = a.annotationType();
        //跳过所有java.lang.annotation下的注解
        if (!aType.getPackageName().equals("java.lang.annotation")) {
            //递归查询组合注解
            A findAnnotation = findAnnotation(aType, annotationClass);
            if (findAnnotation != null) {
                if (annotation != null) {
                    //被重复注解，应该报错
                    throw new BeanDefinitionException(String.format("在类 %s 上发现了多个相同注解 @%s", target.getSimpleName(), annotationClass.getSimpleName()));
                }
                annotation = findAnnotation;//否则就返回递归发现的注解
            }
        }
    }
    return annotation;
}
```

此外，Spring允许给Bean起自己的名称，通过@Component("xxx")及其对应的组合注解，并在没有配置value的时候启用默认名称，也就是类简名的首字母小写版本，因此我们需要一个工具方法获取Bean的Class对应的名称

还有获取构造函数，获取@Order，@PostConstruct等信息的功能，我们统一在ClassUtils中编写工具方法

在ClassUtils添加下列方法

```java
/**
* 获取Bean的名称
* @param clazz Bean
* @return 名称
*/
public static String getBeanName(Class<?> clazz) {
    String name = "";
    //先查找直接被@Component注解的类
    Component component = clazz.getAnnotation(Component.class);
    if (component != null) {
        //@Component存在
        name = component.value();
    } else {
        //@Component不存在，查找带有@Compoenet的组合注解，比如@Service("serviceName")
        for (Annotation a : clazz.getAnnotations()) {
            if (findAnnotation(a.annotationType(), Component.class) != null) {
                //这是一个带有@Component的组合注解
                try {
                    //需要执行a的value方法，但是编译时不知道a有没有这个方法，上面的if已经保证其有这个方法，因此我们靠反射调用
                    name = (String) a.annotationType().getMethod("value").invoke(a);
                } catch (ReflectiveOperationException e) {
                    throw new BeanCreationException(String.format("无法获取注解@%s的value属性", a),e);
                }
            }
        }
    }
    if (name.isEmpty()) {
        //没有配置value属性，默认Bean名称是简单名称的首字母小写版本
        name = clazz.getSimpleName();
        name = Character.toLowerCase(name.charAt(0)) + name.substring(1);
    }
    return name;
}

/**
* 获取Class唯一的(public)构造函数
* @param clazz 类class
* @return 唯一构造函数
*/
@Nullable//当扫描的是接口时返回null
public static Constructor<?> getSuitableConstructor(Class<?> clazz) {
    //接口没有构造方法
    if (clazz.isInterface()) {
        return null;
    }
    Constructor<?>[] constructors = clazz.getConstructors();
    if (constructors.length == 0) {
        constructors = clazz.getDeclaredConstructors();
        if (constructors.length > 1) {
            throw new BeanDefinitionException(String.format("在类 %s 中找到了超过1个构造函数", clazz.getSimpleName()));
        }
    } else if (constructors.length > 1) {
        throw new BeanDefinitionException(String.format("在类 %s 中找到了超过1个public构造函数", clazz.getSimpleName()));
    }
    return constructors[0];
}

/**
* 获取Bean的Order属性，越小优先级越高，没有对应注解的优先级在最后
* @param clazz 需要查找的Bean
* @return 优先级
*/
public static int getOrder(Class<?> clazz) {
    Order order = clazz.getAnnotation(Order.class);
    return order == null ? Integer.MAX_VALUE : order.value();
}

/**
* 获取被annotationClass注解的唯一方法，主要用于扫描@PostConstruct和@PreDestory，方法必须没有参数
* @param clazz 需要扫描的Bean
* @param annotationClass 匹配的注解
* @return 找到的方法
*/
public static Method getUniqueNoParamsAnnotationMethod(Class<?> clazz, Class<? extends Annotation> annotationClass) {
    //找到所有annotationClass注解的无参方法
    List<Method> methods = Arrays.stream(clazz.getDeclaredMethods()).filter(m -> m.isAnnotationPresent(annotationClass)).peek(m -> {
        if (m.getParameterCount() != 0) {
            throw new BeanDefinitionException(String.format("被@%s注解的方法 %s 必须没有参数", annotationClass, m));
        }
    }).toList();
    if (methods.isEmpty()) {
        return null;
    }
    if (methods.size() > 1) {
        throw new BeanDefinitionException(String.format("不允许有多个方法被@%s注解", annotationClass));
    }
    return methods.getFirst();
}
```

此外@Configuration下被@Bean注册的方法也可以配置名字，也有可能被@Order注解，因此对应`getBeanName()``getOrder()`方法，还需要添加参数为`Method`的重载版本

```java
/**
* 获取Bean的名称，默认是方法名
* @param method 方法
* @return 名称
*/
public static String getBeanName(Method method) {
    Bean bean = method.getAnnotation(Bean.class);
    String name = bean.value();
    if (name.isEmpty()) {
        return method.getName();
    }
    return name;
}

/**
    * 获取方法的Order属性，越小优先级越高，没有对应注解的优先级在最后
    * @param method 需要查找的方法
    * @return 优先级
    */
public static int getOrder(Method method) {
    Order order = method.getAnnotation(Order.class);
    return order == null ? Integer.MAX_VALUE : order.value();
}
```

完成了这些工具方法，我们就来到最核心的部分，通过@ComponentScan和@Import扫描所有Bean的名字（**这里的名字不再是我们在Resource定义的/分隔，.class结尾的名字，而就是Java的类全限定名，用.隔开，没有.class结尾**），并通过名字把Bean的类注册成BeanDefinition，以Map<String,BeanDefinition>的形式存储

目前我们只对注解在启动类上的@Import提供支持，也就是@ComponentScan注解的类，用于传入`scanForClassNames()`的参数

1. 获取到@ComponentScan并通过配置的包获取所有Class名字
2. 根据名字注册BeanDefinition，保存到Map<String,BeanDefinition>中
3. 在构造函数调用这包扫描，注册Bean的两个方法完成容器的构造，注意PropertyResolver也是属性，用于@Value的注入

首先是包扫描

要注意的是，@Import引入的class文件我们把它也视为Bean，也获取它的名字

在AnnotationConfigApplicationContext定义方法

注意的是把我们Resource的名字转换成Java的类全限定名的形式

```java
private Set<String> scanForClassNames(Class<?> configClass) {
    //获取@ComponentScan
    ComponentScan scan = ClassUtils.findAnnotation(configClass, ComponentScan.class);

    String[] basePackages = scan.value();
    Set<String> classNameSet = new HashSet<>();

    //如果没有配置任何扫描范围，默认扫描启动类所在包
    if (basePackages == null || basePackages.length == 0) {
        basePackages = new String[]{configClass.getPackage().getName()};
    }

    //逐个包扫描
    for (String basePackage : basePackages) {
        //先前定义的资源处理器，扫描封装资源
        ResourceResolver resolver = new ResourceResolver(basePackage);
        List<String> classNameList = resolver.scan(resource -> {
            String name = resource.name();
            //移除.class后缀，替换/或者\为.，转化成Java可用的类全限定名称
            if (name.endsWith(".class")) {
                name = name.substring(0, name.length() - 6).replace('/', '.').replace('\\', '.');
            }
            return name;
        });
        classNameSet.addAll(classNameList);
    }

    //还要导入@Import的class
    Import importAnnotation = configClass.getAnnotation(Import.class);
    if (importAnnotation != null) {
        Class<?>[] imports = importAnnotation.value();
        for (Class<?> importClass : imports) {
            classNameSet.add(importClass.getName());
        }
    }
    
    return classNameSet;
}
```

然后是根据名字注册BeanDefinition，保存到Map<String,BeanDefinition>中

通过@Bean注册的Bean没有intiMethod和destoryMetohd，因为其的实际类型不一定和工厂方法返回的类型一致，不应该从BeanDefinition（是工厂方法返回的类型）的Class反射获取方法，而是要从实例的Class获取

注意我们的ClassUtils.getSuitableConstructor()只允许有一个构造函数或多个构造函数只有一个public，实际使用时最好不写构造函数只通过字段注入

```java
/**
* 查找classNameSet的名字的对应Bean并返回Bean的Map<String,BeanDefinition>结构
* @param classNameSet Bean的名字集合，名字是Bean的类的全限定名
* @return Bean的Map<String,BeanDefinition>结构
*/
private Map<String,BeanDefinition> createBeanDefinitions(Set<String> classNameSet) {
    Map<String,BeanDefinition> beanDefinitionMap = new HashMap<>();
    for (String className : classNameSet) {
        Class<?> clazz;
        try {
            clazz = Class.forName(className);
        } catch (ClassNotFoundException e) {
            throw new BeanCreationException(e);
        }

        //只有被@Component注解的才是Bean，注意@Component可能是某个组合注解的一部分，因此要ClassUtils的递归查询
        Component component = ClassUtils.findAnnotation(clazz,Component.class);
        if (component != null) {
            String beanName = ClassUtils.getBeanName(clazz);
            Method postConstruct = ClassUtils.getUniqueNoParamsAnnotationMethod(clazz, PostConstruct.class);
            Method preDestroy = ClassUtils.getUniqueNoParamsAnnotationMethod(clazz, PreDestroy.class);
            BeanDefinition definition = new BeanDefinition(
                    beanName,
                    clazz,
                    ClassUtils.getSuitableConstructor(clazz),
                    ClassUtils.getOrder(clazz),
                    clazz.isAnnotationPresent(Primary.class),
                    postConstruct.getName(),
                    preDestroy.getName(),
                    postConstruct,
                    preDestroy
            );
            addBeanDefinition(beanDefinitionMap, definition);

            //如果这个Bean是@Configuration，我们还要载入其方法的@Bean
            if (clazz.isAnnotationPresent(Configuration.class)) {
                scanFactoryMethods(clazz,beanName,beanDefinitionMap);
            }
        }
    }
    return beanDefinitionMap;
}

//把BeanDefinition放入Map，重复时抛出异常
private void addBeanDefinition(Map<String,BeanDefinition> definitions, BeanDefinition beanDefinition) {
    String beanName = beanDefinition.getName();
    if (definitions.containsKey(beanName)) {
        throw new BeanDefinitionException("多个Bean的名称具有相同的名字: " + beanName);
    }
    definitions.put(beanName, beanDefinition);
    logger.atDebug().log("注册了Bean: {}", beanDefinition);
}

/**
* 扫描类下被@Bean注解的方法，以工厂方法的形式注册
* @param clazz 工厂类，就是@Configuration注解的类
* @param beanName 工厂类名称
* @param beanDefinitionMap Bean的Map<String,BeanDefinition>结构
*/
private void scanFactoryMethods(Class<?> clazz, String beanName, Map<String, BeanDefinition> beanDefinitionMap) {
    for (Method method : clazz.getDeclaredMethods()) {
        Bean bean = method.getAnnotation(Bean.class);
        if (bean != null) {
            int modifier = method.getModifiers();
            if (Modifier.isAbstract(modifier)) {
                throw new BeanDefinitionException("@Bean注解的方法" + clazz.getName() + "." + method.getName() + "不允许为abstract");
            }
            if (Modifier.isPrivate(modifier)) {
                throw new BeanDefinitionException("@Bean注解的方法" + clazz.getName() + "." + method.getName() + "不允许为private");
            }
            if (Modifier.isFinal(modifier)) {
                throw new BeanDefinitionException("@Bean注解的方法" + clazz.getName() + "." + method.getName() + "不允许final");
            }
            Class<?> returnType = method.getReturnType();
            if (returnType.isPrimitive()) {
                throw new BeanDefinitionException("@Bean注解的方法" + clazz.getName() + "." + method.getName() + "不允许返回基本类型");
            }
            if (returnType.equals(void.class) || returnType.equals(Void.class)) {
                throw new BeanDefinitionException("@Bean注解的方法" + clazz.getName() + "." + method.getName() + "不允许返回void");
            }
            BeanDefinition definition = new BeanDefinition(
                    ClassUtils.getBeanName(method),
                    returnType,
                    beanName,
                    method,
                    ClassUtils.getOrder(method),
                    method.isAnnotationPresent(Primary.class),
                    bean.initMethod().isEmpty() ? null : bean.initMethod(),
                    bean.destroyMethod().isEmpty() ? null : bean.destroyMethod(),
                    null, //因为returnType不一定是Bean返回的真正类型（可能是父类，这里的方法必须从实例获取）
                    null
            );
            addBeanDefinition(beanDefinitionMap, definition);
        }
    }
}
```

最后，我们在构造函数调用这两个方法完成注册，注意PropertyResolver也是属性，用于@Value的注入

```java
//保存Bean的注册
private final Map<String,BeanDefinition> beans;

//用于@Value的配置读取
private final PropertyResolver propertyResolver;

public AnnotationConfigApplicationContext(Class<?> configClass, PropertyResolver propertyResolver) {
    this.propertyResolver = propertyResolver;
    Set<String> beanNames = scanForClassNames(configClass);
    this.beans = createBeanDefinitions(beanNames);
}
```

现在我们就完成了Bean注册的全部工作，注意注册只是把Bean的BeanDefinition信息加载到Map<String,BeanDefinition>的过程，其中BeanDefinition的instance是null，还没有实例化，实例化的过程在后面探索

##### @Configuration的解析

@Bean只能注解在方法上，用这个方法拿到Bean的实例，而Java的方法必须属于某个类，因此必须有一个额外的类存放这些方法，也就是@Configuration注解的类

@Configuration注解的类也必须注册成Bean，因为我们只有通过这个Bean的实例才能调用@Bean注解的方法，拿到对应实例

#### 获取Bean的早期实例（构造/工厂方法生成Bean）

Spring支持4种依赖注入的形式

- 构造方法：@Autowired在构造函数上
- 工厂方法：@Autowired在工厂方法上
- setter：@Autowired在setter方法上
- 字段：@Autowired直接在字段上

只有后两种，Setter方法注入和属性注入，Bean的创建与注入是可以分开的，即先创建Bean实例，再用反射调用方法或字段，完成注入

把必须调用的构造方法注入和工厂方法注入的final依赖称为强依赖，不能有强依赖的循环依赖

可以有弱依赖的循环依赖，假设A，B循环依赖，可以先创建无依赖的A，再创建B并注入无依赖的A，最后修改A的B字段为我们创建的B实例，由于B的依赖是A的引用，A已经被注入了B，此时B里面的A也是有依赖的A

因此对于IoC容器来说，创建Bean的过程分两步：

- 创建Bean的实例，此时必须注入强依赖，此阶段遇到的循环依赖必须报错
- 对Bean实例进行Setter方法注入和字段注入

先完成创建早期实例的方法（不进行Setter和字段注入）

需要预先准备的方法：

通过类型或者名字查找Bean

在AnnotationConfigApplicationContext类下定义以下方法

```java
//找到所有类型符合的Bean
private List<BeanDefinition> findMatchedBeanDefinitionsByType(Class<?> type) {
    return this.beans.values().stream().filter(definition -> type.isAssignableFrom(definition.getBeanClass())).sorted().toList();
}

/**
* 通过类型找到唯一Bean，有多个返回@Primary
* @param type 类型
* @return 找到的Bean
*/
@Nullable
public BeanDefinition findBeanDefinitionByType(Class<?> type) {
    List<BeanDefinition> allMatchedBeans = findMatchedBeanDefinitionsByType(type);
    if (allMatchedBeans.isEmpty()) {
        return null;
    }
    if (allMatchedBeans.size() == 1) {
        return allMatchedBeans.getFirst();
    }
    //多个必须查询Primary
    List<BeanDefinition> primary = allMatchedBeans.stream().filter(BeanDefinition::isPrimary).toList();
    if (primary.size() == 1) {
        return primary.getFirst();
    }
    if (primary.isEmpty()) {
        throw new NoUniqueBeanDefinitionException(String.format("多个符合类型 %s 的Bean被找到，且没有@Primary注解", type.getName()));
    } else {
        throw new NoUniqueBeanDefinitionException(String.format("多个符合类型 %s 的Bean被找到，且有多个@Primary注解", type.getName()));
    }
}

/**
* 通过名字找到唯一Bean，没有返回null
* @param name Bean的名字
* @param type Bean的类型，找到的Bean类型不匹配是抛出异常
* @return 找到的Bean
*/
@Nullable
public BeanDefinition findBeanDefinitionByNameAndType(String name, Class<?> type) {
    BeanDefinition beanDefinition = beans.get(name);
    //没有时返回null
    if (beanDefinition == null) {
        return null;
    }
    if (!beanDefinition.getBeanClass().isAssignableFrom(type)) {
        throw new BeanNotOfRequiredTypeException(String.format("找到的Bean类型%s与所需的类型%s不匹配",beanDefinition.getBeanClass().getName(),type.getName()));
    }
    return beanDefinition;
}
```

通过Bean名字直接获取Bean实例

```java
/**
* 根据名字获取Bean实例，为null时抛出异常
* @param name Bean名字
* @return Bean实例
* @param <T> Bean实例类型
*/
public <T> T getBean(String name) {
    BeanDefinition d = beans.get(name);
    if (d == null) {
        throw new NoSuchBeanDefinitionException(String.format("没有名字为 '%s' 的Bean", name));
    }
    return (T) d.getRequiredInstance();
}
```

创建早期实例

1. 先检查是否是已经创建的实例，如果出现说明有强循环依赖
2. 确认对应的BeanDefinition是否已经有可用的构造方法或工厂方法
3. 获取方法参数，对于@Value的利用PropertyResolver获取，对于@Autowired的从利用类型或者名字找到对应BeanDefinition，如果这个BeanDefinition还没有实例还需要递归创建其实例。此外，@Configuration注解的是工厂类，不允许使用@Autowired注入构造函数参数
4. 通过反射，调用构造方法或者工厂方法使用先前获取的方法参数创建实例，并注入BeanDefinition

```java
/**
* 为Bean定义d创建早期实例并注入，没有字段和setter的注入
* @param d Bean的定义
* @return 创建的实例
*/
private Object createBeanAsEarlySingleton(BeanDefinition d) {
    logger.atDebug().log("创建早期单例Bean实例，名称: {}， 类型: {}", d.getName(), d.getBeanClass().getName());
    //查找是否已经创建过，如果有就是循环依赖
    if (!this.creatingBeanNames.add(d.getName())) {
        throw new UnsatisfiedDependencyException(String.format("在创建Bean %s 时发现了循环依赖", d.getName()));
    }

    //查找创建方法：构造器/工厂方法，Executable是Constructor和Method的父类
    Executable function = d.getFactoryName() == null ? d.getConstructor() : d.getFactoryMethod();//有工厂类名就是工厂方法创建
    if (function == null) {
        throw new BeanCreationException(String.format("没有找到Bean %s 的可用创建方法", d.getName()));
    }

    //获取创建方法参数
    Parameter[] parameters = function.getParameters();
    Object[] args = new Object[parameters.length];
    for (int i = 0; i < parameters.length; i++) {
        Parameter parameter = parameters[i];
        Annotation[] annotations = parameter.getAnnotations();
        Value value = ClassUtils.getParamAnnotation(parameter, Value.class);
        Autowired autowired = ClassUtils.getParamAnnotation(parameter, Autowired.class);

        //不允许在@Confiuration的依赖上使用@Autowired
        final boolean isConfiguration = isConfigurationBean(d);
        if (autowired != null && isConfiguration) {
            throw new BeanCreationException(String.format("不允许在@Configuration的Bean %s 的构造方法使用@Autowired", d.getName()));
        }

        //检查注解，不能同时被两者注解或都不被注解
        if (autowired != null && value != null) {
            throw new BeanCreationException(String.format("在调用有参构造函数创建Bean %s:%s 时发现了不允许的操作，对同一个参数同时注解@Autowired和@Value", d.getName(), d.getBeanClass().getName()));
        }
        if (autowired == null && value == null) {
            throw new BeanCreationException(String.format("在调用有参构造函数创建Bean %s:%s 时发现了不允许的操作，存在参数没有被@Autowired或@Value注解", d.getName(), d.getBeanClass().getName()));
        }

        //开始注入
        Class<?> type = parameter.getType();
        if (value != null) {
            //是@Value注解
            args[i] = propertyResolver.getRequiredProperty(value.value(), type);
        } else {
            //是@Autowired注解
            boolean required = autowired.value();
            String name = autowired.name();
            BeanDefinition dependency = name == null ? findBeanDefinitionByType(type) : findBeanDefinitionByNameAndType(name, type);
            //必要的依赖没有对应的Bean，抛出异常
            if (required && dependency == null) {
                throw new BeanCreationException(String.format("创建Bean %s 失败，自动装配无法找到符合类型%s的Bean", d.getName(), type.getName()));
            }
            //找到了依赖
            if (dependency != null) {
                Object instance = dependency.getInstance();
                if (instance == null) {
                    //没有对应实例，递归创建依赖的实例
                    instance = createBeanAsEarlySingleton(dependency);
                }
                args[i] = instance;
            }
            args[i] = null;//@Autowired是不一定需要的，也没有对应Bean的情况
        }
    }

    //创建Bean实例
    Object instance = null;
    if (d.getFactoryName() == null) {
        //是构造方法创建
        try {
            instance = d.getConstructor().newInstance(args);
        } catch (Exception e) {
            throw new BeanCreationException(String.format("创建Bean %s:%s 时发生异常", d.getName(), d.getBeanClass().getName()), e);
        }
    } else {
        //是工厂方法创建
        try {
            instance = d.getFactoryMethod().invoke(this.getBean(d.getFactoryName()),args);
        } catch (Exception e) {
            throw new BeanCreationException(String.format("创建Bean %s:%s 时发生异常", d.getName(), d.getBeanClass().getName()), e);
        }
    }
    d.setInstance(instance);
    return d.getInstance();
}
```

最后在AnnotationConfigApplicationContext的构造函数对每个Map里的BeanDefinition调用`createBeanAsEarlySingleton()`方法注入早期实例，注意@Configuration的是工厂类，必须先创建所有的工厂类实例才能在普通Bean的创建中（如果有）调用工厂方法

```java
public AnnotationConfigApplicationContext(Class<?> configClass, PropertyResolver propertyResolver) {
    //完成Bean的注册
    this.propertyResolver = propertyResolver;
    Set<String> beanNames = scanForClassNames(configClass);
    this.beans = createBeanDefinitions(beanNames);
    this.creatingBeanNames = new HashSet<>();

    //找到所有@Configuration的Bean，优先实例化它们才能调用@Bean的工厂方法
    this.beans.values().stream().filter(this::isConfigurationBean).forEach(d -> {
        createBeanAsEarlySingleton(d);
        creatingBeanNames.add(d.getName());
    });

    //创建其它还没有实例的Bean
    this.beans.values().stream().filter(d -> d.getInstance() == null).forEach(d -> {
        //还要判断一次是因为可能已经被递归创建
        if (d.getInstance() == null) {
            createBeanAsEarlySingleton(d);
            creatingBeanNames.add(d.getName());
        }
    });
}
```

#### 进行Bean的初始化（字段，setter注入，@PostConstruct）

需要预先准备的方法

```java
/**
* 检查字段或方法是否允许注入，static不允许注入，final字段不允许注入
* @param acc 字段或者方法
*/
private void checkFieldAndMethod(Member acc) {
    int modifiers = acc.getModifiers();
    if (Modifier.isStatic(modifiers)) {
        throw new BeanDefinitionException("无法注入static字段或者跳过static方法注入对象 " + acc);
    }
    if (Modifier.isFinal(modifiers)) {
        if (acc instanceof Field) {
            throw new BeanDefinitionException("无法注入final字段 " + acc);
        } else if (acc instanceof Method) {
            logger.warn("final方法可能在代理类中消失，谨慎使用final方法注入，可能导致NullPointerException :" + acc);
        }
    }
}
```

接下来进行单个Bean的依赖的注入，分为几步

1. 扫描Bean的Class的所有Field和Method，找到被@Value和@Autowired注解的对象，注意父类的字段注解也应该被子类继承，所以还需要在父类搜索注解。注意注解的搜索Class一定是实际类型的Class，通过`beanDefinition.getInstance().getClass()`获取（在`injectBean()`）

2. 注入被注解的对象：Value的依赖从PropertyResolver加载，Autowired利用之前在步骤 **获取Bean的早期实例（构造/工厂方法生成Bean）** 定义的`findBeanDefinitionByType()`和`findBeanDefinitionByNameAndType()`加载，字段通过Field的set方法注入，setter通过Method的invoke方法注入

```java
/**
* 为当前的BeanDefinition中的实例注入属性
* @param beanDefinition 当前的BeanDefinition
*/
private void injectBean(BeanDefinition beanDefinition) {
    try {
        //注意调用的类型一定是实例的实际类型，因为也可能是@Bean
        injectBeanProperties(beanDefinition,beanDefinition.getInstance().getClass(),beanDefinition.getInstance());
    } catch (ReflectiveOperationException e) {
        throw new BeanCreationException(e);
    }
}

/**
* 为当前的BeanDefinition中的实例注入属性
* @param beanDefinition 当前的BeanDefinition
* @param beanClass 当前的BeanDefinition的类型
* @param bean 当前的BeanDefinition的实例
*/
private void injectBeanProperties(BeanDefinition beanDefinition, Class<?> beanClass, Object bean) throws ReflectiveOperationException {
    //查找字段
    for (Field field : beanClass.getDeclaredFields()) {
        tryInjectOnProperties(beanDefinition,beanClass,bean,field);
    }
    //查找方法
    for (Method method : beanClass.getDeclaredMethods()) {
        tryInjectOnProperties(beanDefinition,beanClass,bean,method);
    }
    //在其父类也进行查找，因为子类也继承了这些属性的注解但是反射不到
    Class<?> superclass = beanClass.getSuperclass();
    if (superclass != null) {
        injectBeanProperties(beanDefinition,superclass,bean);//这里的Bean依然是我们注入的Bean
    }
}

/**
* 尝试注入单个的@Value或者@Autowired
* @param beanDefinition 当前的BeanDefinition
* @param beanClass 当前的BeanDefinition的类型
* @param bean 当前的BeanDefinition的实例
* @param acc 当前要出任的对象，可以是Field或者Method
*/
private void tryInjectOnProperties(BeanDefinition beanDefinition, Class<?> beanClass, Object bean, AccessibleObject acc) throws ReflectiveOperationException {
    Value value = acc.getAnnotation(Value.class);
    Autowired autowired = acc.getAnnotation(Autowired.class);
    if (value == null && autowired == null) {
        //跳过没有被注解的对象
        return;
    }

    Field field = null;
    Method method = null;
    if (acc instanceof Field f) {
        checkFieldAndMethod(f);
        f.setAccessible(true);
        field = f;
    } else if (acc instanceof Method m) {
        checkFieldAndMethod(m);
        if (m.getParameters().length != 1) {
            //setter方法只允许一个参数
            throw new BeanDefinitionException(String.format("使用setter注入bean %s:%s 的方法 %s 必须只有一个参数", beanDefinition.getName(), beanClass, m));
        }
        m.setAccessible(true);
        method = m;
    }

    String accessibleName = field == null ? method.getName() : field.getName();
    Class<?> accessibleType = field == null ? method.getParameterTypes()[0] : field.getType();
    if (value != null && autowired != null) {
        throw new BeanDefinitionException(String.format("不允许对Bean %s:%s 的同一个对象 %s 同时使用@Autowired和@Value", beanDefinition.getName(), beanClass.getName(), accessibleName));
    }

    //@Value注入
    if (value != null) {
        Object propertyValue = propertyResolver.getRequiredProperty(value.value(), accessibleType);
        if (field != null) {
            logger.atDebug().log("字段注入: {}.{} = {}", beanClass.getSimpleName(), accessibleName, propertyValue);
            field.set(bean, propertyValue);
        } else if (method != null) {
            logger.atDebug().log("setter注入: {}.{} = {}", beanClass.getSimpleName(), accessibleName, propertyValue);
            method.invoke(bean, propertyValue);
        }
    }

    //@Autowired注入
    if (autowired != null) {
        String name = autowired.name();
        boolean required = autowired.value();
        BeanDefinition dependency = name == null || name.isEmpty() ? findBeanDefinitionByType(accessibleType) : findBeanDefinitionByNameAndType(name, accessibleType);
        if (required && dependency == null) {
            throw new UnsatisfiedDependencyException(String.format("在注入%s.%s时找不到对应的依赖 %s:%s", beanClass.getSimpleName() , accessibleName, beanDefinition.getName(), beanDefinition.getBeanClass().getName()));
        }
        if (dependency != null) {
            if (field != null) {
                logger.atDebug().log("字段注入: {}.{} = {}", beanClass.getSimpleName(), accessibleName, dependency);
                field.set(bean, dependency.getInstance());
            } else if (method != null) {
                logger.atDebug().log("setter注入: {}.{} = {}", beanClass.getSimpleName(), accessibleName, dependency);
                method.invoke(bean, dependency.getInstance());
            }
        }
    }
}
```

最后再执行@PostConstruct的方法就可以完成初始化。还记得BeanDefinition包含两个字段吗：intiMethod，intiMethodName。这就是用在这一步的。其中@Bean的Bean的intiMethod是null，因为他的实例不一定是BeanDefinition里的类型，必须从实例获取，因此方法需要三个参数：bean的实例，intiMethod，intiMethodName

```java
/**
* 在实例上调用指定方法
* @param instance 实例
* @param methodName 方法名称
* @param method 方法
*/
private void callMethod(Object instance, String methodName, Method method) {
    if (method != null) {
        //是@Component的Bean，直接有方法
        try {
            method.invoke(instance);
        } catch (ReflectiveOperationException e) {
            throw new BeanCreationException(e);
        }
    } else if (methodName != null) {
        //是@Bean的Bean，需要通过名字从实例的Class获取方法
        Method namedMethod = ClassUtils.getNamedMethod(instance.getClass(), methodName);
        namedMethod.setAccessible(true);
        try {
            namedMethod.invoke(instance);
        } catch (ReflectiveOperationException e) {
            throw new BeanCreationException(e);
        }
    }
}
```

在ClassUtils里添加如下方法

```java
/**
* 通过名称查找Class上的方法，不存在时抛出一次
* @param clazz Class
* @param name 方法名称
* @return 找到的方法Method
*/
@NotNull
public static Method getNamedMethod(Class<?> clazz, String name) {
    try {
        return clazz.getDeclaredMethod(name);
    } catch (NoSuchMethodException e) {
        throw new BeanDefinitionException(e);
    }
}
```

最后我们在AnnotationConfigApplicationContext的构造方法再添加以下部分

1. 对所有bean进行字段/setter注入
2. 执行所有bean的intiMethod

```java
public AnnotationConfigApplicationContext(Class<?> configClass, PropertyResolver propertyResolver) {
    //完成Bean的注册
    this.propertyResolver = propertyResolver;
    Set<String> beanNames = scanForClassNames(configClass);//扫描所有@Component，@Import并把名字（全限定名添加进去
    this.beans = createBeanDefinitions(beanNames);//注册所有Bean

    //实例化时用这个发现强循环依赖
    this.creatingBeanNames = new HashSet<>();

    //找到所有@Configuration的Bean，优先实例化它们才能调用@Bean的工厂方法
    this.beans.values().stream().filter(this::isConfigurationBean).sorted().forEach(d -> {
        createBeanAsEarlySingleton(d);
        creatingBeanNames.add(d.getName());
    });

    //创建其它还没有实例的Bean
    this.beans.values().stream().filter(d -> d.getInstance() == null).sorted().forEach(d -> {
        //还要判断一次是因为可能已经被递归创建
        if (d.getInstance() == null) {
            createBeanAsEarlySingleton(d);
            creatingBeanNames.add(d.getName());
        }
    });

    //为所有BeanDefinition进行字段/setter注入
    this.beans.values().forEach(this::injectBean);

    //为所有的BeanDefinition执行@PostConstruct方法，也就是intiMethod
    //注意@Bean注册的BeanDefinition没有intiMethod，需要从名字判断，因此还要传入名字参数
    this.beans.values().forEach(d -> this.callMethod(d.getInstance(), d.getInitMethodName(), d.getInitMethod()));
}
```

#### 实现@PreDestory

只需要提供一个`close()`方法，容器关闭时遍历所有Bean并执行`callMethod()`，流程和@PostConstruct基本相同

```java
/**
* 关闭容器，将调用所有Bean的desoryMethod
*/
public void close() {
    this.beans.values().forEach(d -> this.callMethod(d.getInstance(), d.getDestroyMethodName(), d.getDestroyMethod()));
}
```

现在直接调用此方法是手动关闭容器，可以执行@PreDestroy，如果要让JVM退出时执行这个方法，关闭容器的名称必须叫`close()`，然后实现`AutoCloseable`接口

#### 实现BeanPostProcessor，提供动态代理功能

BeanPostProcessor接口用于向IoC注册一个替换方法，当检测到符合条件的Bean的实例就替换成BeanPostProcessor的实现类中方法替换成的实例。这个BeanPostProcessor接口也要注册为Bean

BeanPostProcessor接口提供以下方法，当bean是需要被代理的类时返回代理类，否则返回bean本身

```java
//被其它Bean依赖时，应该使用的实例
Object postProcessBeforeInitialization(Object bean, String beanName);
```

示例

```java
@Bean
BeanPostProcessor createProxy() {
    return new BeanPostProcessor() {
        @Override
        public Object postProcessBeforeInitialization(Object bean, String beanName) throws BeansException {
            // 实现事务功能:
            if (bean instanceof UserService u) {
                return new UserServiceProxy(u);
            }
            return bean;
        }
    };
}
```

被替换的类实例会被IoC容器“丢弃”，或者说是IoC容器不再管理被替换的原始类

替换的Proxy类依然需要调用原始类的方法执行实际逻辑，因此该类的依赖必须注入原始类。而该类被使用时必须使用代理类才能实现代理功能

- 一个Bean如果被Proxy替换，则依赖它的Bean应注入Proxy
- 一个Bean如果被Proxy替换，如果要注入依赖，则应该注入到原始对象

要满足条件1，只需要构造完早期Bean后立刻用Proxy替换它即可，我们可以先构造所有带有BeanPostProcessor的Bean的实例，再构造其它普通Bean的实例

```java
//所有BeanPostProcessor类型的实例
private final List<BeanPostProcessor> beanPostProcessors;

public AnnotationConfigApplicationContext(Class<?> configClass, PropertyResolver propertyResolver) {
    ...

    this.beanPostProcessors = new ArrayList<>();

    //找到所有@Configuration的Bean，优先实例化它们才能调用@Bean的工厂方法
    this.beans.values().stream().filter(this::isConfigurationBean).forEach(d -> {
        createBeanAsEarlySingleton(d);
        creatingBeanNames.add(d.getName());
    });

    //先初始化所有BeanPostProcessor类型的实例

    this.beans.values().stream().filter(this::isBeanPostProcessor).forEach(d -> {
        createBeanAsEarlySingleton(d);
        beanPostProcessors.add((BeanPostProcessor) d.getInstance());
    });


    //创建其它还没有实例的Bean
    this.beans.values().stream().filter(d -> d.getInstance() == null).forEach(d -> {
        //还要判断一次是因为可能已经被递归创建
        if (d.getInstance() == null) {
            createBeanAsEarlySingleton(d);
            creatingBeanNames.add(d.getName());
        }
    });

    ...
}
```

在创建早期实例的`createBeanAsEarlySingleton()`方法添加以下内容，在早期实例一创建好就立刻按顺序调用可能的processor进行处理

**请注意，这里判断代理类和原始类相同不要用processBean.equals(instance)，有些字节码生成框架如Byte Buddy生成的代理类会重写`equals()`导致processBean.equals(instance)即使是代理类判断和原始类是否相同时返回true**

```java
private Object createBeanAsEarlySingleton(BeanDefinition d) {
    ...

    //instance是前面创建好的原始实例

    //遍历所有BeanPostProcessor找到其可能的processor进行替换
    for (BeanPostProcessor processor : beanPostProcessors) {
        Object processBean = processor.postProcessBeforeInitialization(d.getInstance(), d.getName());
        if (processBean == null) {
            throw new BeanCreationException(String.format("BeanPostProcessor: %s 对Bean: %s 的处理结果返回了null", processor, d.getName()));
        }
        //只有成功代理时结果才会不同
        //这里必须用==，不能用equals，因为Byte Buddy生成的代理类重写的equals方法，会导致其和原始类是一致的
        if (!(processBean == instance)) {
            logger.atDebug().log("BeanPostProcessor: {} 对Bean: {} 的处理将其实例从 {} 替换为了 {}", processor, d.getName(), d.getInstance() ,processBean);
            d.setInstance(processBean);
        }
    }

    return d.getInstance();
}
```

要满足条件2，那么BeanPostProcessor这个接口的实现类应该有保存原始Bean实例的能力，也就是说，这个BeanPostProcessor在调用`postProcessBeforeInitialization()`时就应该负责保存原始Bean，、。然后在接口中定义方法

```java
//需要注入其它Bean时，使用的实例，是原始实例，如果这个processor不处理此bean就返回其本身
Object postProcessOnSetProperty(Object bean, String beanName);
```

让Proxy提供这个方法返回原始Bean，IoC管理Proxy就能间接管理原始Bean，进行依赖注入时如果发现是BeanPostProcessor，就拿到其原始实例在注入

然后修改注入依赖的`injectBean()`方法，保证如果其要注入的对象是Proxy，就注入到其原始对象

```java
void injectBean(BeanDefinition def) {
    // 获取Bean实例，或被代理的原始实例:
    Object beanInstance = getProxiedInstance(def);
    try {
        injectProperties(def, def.getBeanClass(), beanInstance);
    } catch (ReflectiveOperationException e) {
        throw new BeanCreationException(e);
    }
}

Object getProxiedInstance(BeanDefinition def) {
    Object beanInstance = def.getInstance();
    // 如果Proxy改变了原始Bean，又希望注入到原始Bean，则由BeanPostProcessor指定原始Bean:
    List<BeanPostProcessor> reversedBeanPostProcessors = new ArrayList<>(this.beanPostProcessors);
    Collections.reverse(reversedBeanPostProcessors);
    for (BeanPostProcessor beanPostProcessor : reversedBeanPostProcessors) {
        Object restoredInstance = beanPostProcessor.postProcessOnSetProperty(beanInstance, def.getName());
        if (restoredInstance != beanInstance) {
            beanInstance = restoredInstance;
        }
    }
    return beanInstance;
}
```

执行完初始化后我们让BeanPostProcessor也对这种情况有处理能力，因此修改初始化步骤

```java
public AnnotationConfigApplicationContext(Class<?> configClass, PropertyResolver propertyResolver) {
    ...

    //为所有的BeanDefinition执行@PostConstruct方法，也就是intiMethod
    //注意@Bean注册的BeanDefinition没有intiMethod，需要从名字判断，因此还要传入名字参数
    this.beans.values().forEach(this::initBean);
}

/**
* 对BeanDefinition执行初始化方法和替换成可能的代理
* @param d BeanDefinition
*/
private void initBean(BeanDefinition d) {
    //@PostConstruct是定义在原始类的
    final Object origin = getProxiedInstance(d);
    //调用@PostConstruct方法
    callMethod(origin, d.getInitMethodName(), d.getInitMethod());

    for (BeanPostProcessor processor: beanPostProcessors) {
        Object instance = processor.postProcessAfterInitialization(origin, d.getName());
        if (!instance.equals(origin)) {
            logger.atDebug().log("在初始化类{}的过程中获取到其的代理类{}并使用代理类将其替换", origin.getClass().getSimpleName(), instance.getClass().getSimpleName());
            d.setInstance(instance);
        }
    }
}
```

一个完整的BeanPostProcessor的示例如下

```java
@Order(100)
@Component
public class FirstProxyBeanPostProcessor implements BeanPostProcessor {
    // 保存原始Bean:
    Map<String, Object> originBeans = new HashMap<>();

    @Override
    public Object postProcessBeforeInitialization(Object bean, String beanName) {
        if (OriginBean.class.isAssignableFrom(bean.getClass())) {
            // 检测到OriginBean,创建FirstProxyBean:
            var proxy = new FirstProxyBean((OriginBean) bean);
            // 保存原始Bean:
            originBeans.put(beanName, bean);
            // 返回Proxy:
            return proxy;
        }
        return bean;
    }

    @Override
    public Object postProcessOnSetProperty(Object bean, String beanName) {
        Object origin = originBeans.get(beanName);
        if (origin != null) {
            // 存在原始Bean时,返回原始Bean:
            return origin;
        }
        return bean;
    }
}

// 代理Bean:
public class FirstProxyBean extends OriginBean {
    final OriginBean target;

    public FirstProxyBean(OriginBean target) {
        this.target = target;
    }

    @Override
    public String getName() {
        return target.getName();
    }
}
```

### 收尾工作

我们提取一个用户可用的ApplicationContext接口

```java
public interface ApplicationContext extends AutoCloseable {

    /**
    * 是否存在指定name的Bean？
    * @param name Bean的name
    * @return 是否存在
    */
    boolean containsBean(String name);

    /**
    * 根据name返回唯一Bean，未找到抛出NoSuchBeanDefinitionException
    * @param name Bean的name
    * @return Bean的实例
    * @param <T> Bean实例的类型
    */
    <T> T getBean(String name);

    /**
    * 根据name返回唯一Bean，未找到抛出NoSuchBeanDefinitionException
    * @param name Bean的name
    * @param requiredType Bean实例的类型
    * @return Bean的实例
    * @param <T> Bean实例的类型
    */
    <T> T getBean(String name, Class<T> requiredType);

    /**
    * 根据type返回唯一Bean，未找到抛出NoSuchBeanDefinitionException
    * @param requiredType Bean实例的类型
    * @return Bean的实例
    * @param <T> Bean实例的类型
    */
    <T> T getBean(Class<T> requiredType);

    /**
    * 根据type返回一组Bean，未找到返回空List
    * @param requiredType Bean实例的类型
    * @return 一组Bean的实例
    * @param <T> Bean实例的类型
    */
    <T> List<T> getBeans(Class<T> requiredType);

    /**
    * 关闭并执行所有bean的destroy方法
    */
    void close();
}
```

先前定义的AnnotationConfigApplicationContext是其实现类

```java
public class AnnotationConfigApplicationContext implements ApplicationContext {

    ... //字段

    public AnnotationConfigApplicationContext(Class<?> configClass, PropertyResolver propertyResolver) {
        //完成Bean的注册
        this.propertyResolver = propertyResolver;
        Set<String> beanNames = scanForClassNames(configClass);//扫描所有@Component，@Import并把名字（全限定名添加进去
        this.beans = createBeanDefinitions(beanNames);//注册所有Bean
        this.beanPostProcessors = new ArrayList<>();//预先准备BeanPostProcessor列表

        //实例化时用这个发现强循环依赖
        this.creatingBeanNames = new HashSet<>();

        //找到所有@Configuration的Bean，优先实例化它们才能调用@Bean的工厂方法
        this.beans.values().stream().filter(this::isConfigurationBean).sorted().forEach(d -> {
            createBeanAsEarlySingleton(d);
            creatingBeanNames.add(d.getName());
        });

        //先初始化所有BeanPostProcessor类型的实例
        this.beans.values().stream().filter(this::isBeanPostProcessor).sorted().forEach(d -> {
            createBeanAsEarlySingleton(d);
            beanPostProcessors.add((BeanPostProcessor) d.getInstance());
        });


        //创建其它还没有实例的Bean
        this.beans.values().stream().filter(d -> d.getInstance() == null).sorted().forEach(d -> {
            //还要判断一次是因为可能已经被递归创建
            if (d.getInstance() == null) {
                createBeanAsEarlySingleton(d);
                creatingBeanNames.add(d.getName());
            }
        });

        //为所有BeanDefinition进行字段/setter注入
        this.beans.values().forEach(this::injectBean);

        //为所有的BeanDefinition执行@PostConstruct方法，也就是intiMethod
        //注意@Bean注册的BeanDefinition没有intiMethod，需要从名字判断，因此还要传入名字参数
        this.beans.values().forEach(this::initBean);
    }

    @Override
    public void close() {
        this.beans.values().forEach(d -> this.callMethod(d.getInstance(), d.getDestroyMethodName(), d.getDestroyMethod()));
    }

    @Override
    public boolean containsBean(String name) {
        return this.beans.containsKey(name);
    }

    @Override
    public <T> T getBean(String name) {
        BeanDefinition d = beans.get(name);
        if (d == null) {
            throw new NoSuchBeanDefinitionException(String.format("没有名字为 '%s' 的Bean", name));
        }
        return (T) d.getRequiredInstance();
    }

    @Override
    public <T> T getBean(Class<T> type) {
        BeanDefinition d = findBeanDefinitionByType(type);
        if (d == null) {
            throw new NoSuchBeanDefinitionException(String.format("没有类型为 '%s' 的Bean", type.getSimpleName()));
        }
        return (T) d.getRequiredInstance();
    }

    @Override
    public <T> T getBean(String name, Class<T> requiredType) {
        BeanDefinition d = findBeanDefinitionByNameAndType(name, requiredType);
        if (d == null) {
            throw new NoSuchBeanDefinitionException(String.format("没有名字为 '%s' 的且类型为 %s 的Bean", name, requiredType.getSimpleName()));
        }
        return (T) d.getRequiredInstance();
    }

    @Override
    public <T> List<T> getBeans(Class<T> type) {
        List<BeanDefinition> definitions = findMatchedBeanDefinitionsByType(type);
        return definitions.stream().map(d -> (T) d.getRequiredInstance()).toList();
    }

    ... //private方法
}
```

有时候，IoC容器的某些Bean需要获取到IoC容器本身并取出一个Bean，我们可以定义一个ApplicationContextUtils类，再容器的构造函数中把this载入这个工具类，这样需要容器的Bean在实例化时调用这个工具类的方法就可以拿到自己的IoC容器，避免了容器的反复创建

```java
public class ApplicationContextUtils {

    private static ApplicationContext context = null;

    public static ApplicationContext getRequiredApplicationContext() {
        return Objects.requireNonNull(context, "ApplicationContext is null");
    }

    public static ApplicationContext getRequiredApplicationContext(Class<?> type, String yamlPath) {
        return context;
    }

    public static void setApplicationContext(ApplicationContext context) {
        ApplicationContextUtils.context = context;
    }
}
```

在AnnotationConfigApplicationContext构造函数加上

```java
public AnnotationConfigApplicationContext(Class<?> configClass, PropertyResolver propertyResolver) {

    ApplicationContextUtils.setApplicationContext(this);

    ...
}
```

### IoC的用法

目前我们已经完成了最基本的IoC容器，有几点和Spring不同，需要注意

1. 构造函数构造的初始Bean，构造函数的参数必须用@Autowired或者@Value指定参数的来源
2. 构造函数构造的初始Bean，只允许有一个构造函数，或多个构造函数只有一个public
3. 通过@Bean配置的工厂Bean，@Bean必须指定intiMethod和destoryMethod才能获得和@Component的Bean的@PostConstruct和@PreDestory的效果

代码量相比Spring少得多，因为我们大量简化了Spring的功能，只保留了现在的开发模式下最常用到的Context模式，注解配置等。Spring的许多功能是历史遗留下来的，比如BeanFactory的懒加载模式，xml配置等，现在已经很少使用，因此我们也不实现这些功能。
