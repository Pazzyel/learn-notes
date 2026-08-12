# EasySpring

## Web

Java Web应用一般遵循Servlet标准，其规范定义的组件有3类：

- Servlet：处理HTTP请求，然后输出响应
- Filter：对HTTP请求进行过滤，可以有多个Filter形成过滤器链，实现权限检查、限流、缓存等逻辑
- Listener：用来监听Web应用程序产生的事件，包括启动、停止、Session有修改等

且Servlet标准规定整个服务器为一个应用程序提供一个“容器”Servlet Container，一个Server可以同时跑多个Container，不同的Container可以按URL、域名等区分，Container内部管理Servlet、Filter、Listener这些组件

我们要遵循Servlet规范，所以，Servlet、Filter、Listener，**以及IoC容器**，都必须在Servlet容器内被管理

Servlet容器由什么提供呢？有很多种方案，我们选择Tomcat

对于一个Web应用程序来说，启动时执行的是Server的main()方法。以Tomcat服务器为例：

1. 启动服务器，即执行Tomcat的main()方法
2. Tomcat根据配置或自动检测到一个xxx.war包后，为这个xyz.war应用程序创建Servlet容器
3. Tomcat继续查找xxx.war定义的Servlet、Filter和Listener组件，按顺序实例化每个组件（Listener最先被实例化，然后是Filter，最后是Servlet）
4. 用户发送HTTP请求，Tomcat收到请求后，转发给Servlet容器，容器根据应用程序定义的映射，把请求发送个若干Filter和一个Servlet处理
5. 处理期间产生的事件则由Servlet容器自动调用Listener

实例化组件的方式有：

- 通过在web.xml配置文件中定义，早期方式
- 通过注解@WebServlet、@WebFilter和@WebListener定义，由Servlet容器自动扫描所有class后创建组件，和我们用Annotation配置Bean，由IoC容器自动扫描创建Bean非常类似
- 先配置一个Listener，由Servlet容器创建Listener，然后，Listener自己调用相关接口，手动创建Servlet和Filter

对于使用Spring框架的Web应用程序来说，Servlet、Filter和Listener数量少且固定，而应用程序自身编写的Controller数量不定，由IoC容器管理，采用方式3最合适

因此Tomcat启动Spring的Web程序时初始化步骤是

1. 为Web应用程序准备Servlet容器；
2. 根据配置实例化一个Spring提供的Listener
    1. Spring提供的Listener在初始化时启动IoC容器
    2. Spring提供的Listener在初始化时向Servlet容器注册Spring内置的一个DispatcherServlet
    3. DispatcherServlet初始化时获取到IoC容器中的Controller实例，就可根据URL调用不同Controller实例的不同处理方法

Tomcat把HTTP请求发送给Spring注册的DispatcherServlet，它持有IoC容器的引用，找到对应的Controller实例，把请求继续转发给对应的Controller，处理HTTP请求

Controller并不直接接触Servlet API，而是通过DispatcherServlet这个中间层进行，实现IoC容器的隔离性

### 新增初始Listener和DispatcherServlet

引入Servlet API的依赖

```xml
<dependency>
    <groupId>jakarta.servlet</groupId>
    <artifactId>jakarta.servlet-api</artifactId>
    <version>6.1.0</version>
    <scope>provided</scope>
</dependency>
```

添加我们的DispatcherServlet和ContextLoaderListener，我们当前的DispatcherServlet目前只有发生Hellp World!的html的功能

```java
public class DispatcherServlet extends HttpServlet {
    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        PrintWriter writer = resp.getWriter();
        writer.write("<h1>Hello World!</h1>");
        writer.flush();
    }
}

public class ContextLoaderListener implements ServletContextListener {

    /**
     * 初始Listener初始化调用的方法，创建容器，注册DispatcherServlet
     * @param sce Servlet容器事件
     */
    @Override
    public void contextInitialized(ServletContextEvent sce) {
        ServletContext servletContext = sce.getServletContext();
        ApplicationContext applicationContext = new AnnotationConfigApplicationContext(getApplicationContextClass(servletContext.getInitParameter("configuration")), new PropertyResolver("application.yaml"));
        DispatcherServlet dispatcherServlet = new DispatcherServlet();
        ServletRegistration.Dynamic servletRegistration = servletContext.addServlet("dispatcherServlet", dispatcherServlet);
        servletRegistration.addMapping("/");
        servletRegistration.setLoadOnStartup(0);

        servletContext.setAttribute("applicationContext", applicationContext);
    }

    //获取名称对应的启动类
    private Class<?getApplicationContextClass(String className) {
        if (className == null || className.isEmpty()) {
            throw new NestedRuntimeException("无法启动容器ApplicationContext，初始参数configuration缺失");
        }
        Class<?clazz;
        try {
            clazz = Class.forName(className);
        } catch (ClassNotFoundException e) {
            throw new NestedRuntimeException("无法启动容器ApplicationContext，无法找到初始参数configuration对应的class文件",e);
        }
        return clazz;
    }
}
```

这里我们的`getApplicationContextClass()`是从`web.xml`中读取的，内容大致如下

- `<context-param>`标签配置了启动参数，应该包含`configuration`这一项，值是我们启动类的类全名
- `<listener>`标签配置了我们的初始listener类，值也是`ContextLoaderListener`的全名

```xml
<?xml version="1.0" encoding="UTF-8"?>
<web-app ...>
    <context-param>
        <!-- 固定名称 -->
        <param-name>configuration</param-name>
        <!-- 配置类的完整类名 -->
        <param-value>com.winter.web.WebAppConfig</param-value>
    </context-param>

    <listener>
        <listener-class>com.winter.web.listener.ContextLoaderListener</listener-class>
    </listener>
</web-app>
```

如果需要能够加载`application.yaml`和`application.properties`，可以这样修改

新增一个PropertiesUtils

```java
public class PropertiesUtils {

    private static final Logger logger = LoggerFactory.getLogger(PropertiesUtils.class);

    /**
     * 从path加载Properties
     * @param path properties文件路径
     * @return Properties对象
     */
    public static Properties loadProperties(String path) {
        Properties props = new Properties();
        ClassPathUtils.readInputStream(path, input -{
            logger.atDebug().log("从{}加载了配置", path);
            props.load(input);
            return true;
        });
        return props;
    }
}
```

新增一个WebUtils

```java
public class WebUtils {

    private static final Logger logger = LoggerFactory.getLogger(WebUtils.class.getName());

    public static final String CONFIG_APP_YAML = "application.yaml";
    public static final String CONFIG_APP_PROP = "application.properties";

    /**
     * 从classpath下查找配置文件，优先yaml
     * @return PropertyResolver对象
     */
    public static PropertyResolver createPropertyResolver() {
        PropertyResolver resolver = null;
        try {
            resolver = new PropertyResolver(CONFIG_APP_YAML);
        } catch (UncheckedIOException e) {
            if (e.getCause() instanceof FileNotFoundException) {
                resolver = new PropertyResolver(PropertyUtils.loadProperties(CONFIG_APP_PROP));
            }
        }
        return resolver;
    }
}
```

最后把`ContextLoaderListener`的初始化方法修改如下

```java
@Override
public void contextInitialized(ServletContextEvent sce) {
    ...
    ApplicationContext applicationContext = new AnnotationConfigApplicationContext(
            getApplicationContextClass(servletContext.getInitParameter("configuration")),
            WebUtils.createPropertyResolver()
    );
    ...
}
```

### 实现WebMVC

#### 定义注解

定义需要的注解`@Controller``@RestController`等，注意它们都是`@Component`的组合注解，这里要注意的是反射虽然只能检查最上层的组合注解，但我们前面在`ClassUtils`定义的方法`findAnnotation()`可以递归查找注解，因此`@RestController`要组合`@Component`只需要通过`@Controller`间接组合

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Component
public @interface Controller {
    String value() default "";
}

@Target({ElementType.METHOD, ElementType.TYPE})
@Retention(RetentionPolicy.RUNTIME)
@Documented
public @interface ResponseBody {
}

@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Controller
@ResponseBody
public @interface RestController {
    String value() default "";
}
```

以及各种`@XxxMapping`，它们写法只有名字的不同，以`@GetMapping`为例

```java
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
@Documented
public @interface GetMapping {
    String value();
}
```

还有其他的辅助注解，如`@XxxParam`，`@XxxBody`等

```java
@Target(ElementType.PARAMETER)
@Retention(RetentionPolicy.RUNTIME)
@Documented
public @interface PathVariable {
    String value();
}

@Target(ElementType.PARAMETER)
@Retention(RetentionPolicy.RUNTIME)
@Documented
public @interface RequestParam {
    String value();

    String defaultValue() default WebUtils.DEFAULT_PARAM_VALUE; // "\0\t\0\t\0"
}

@Target(ElementType.PARAMETER)
@Retention(RetentionPolicy.RUNTIME)
@Documented
public @interface RequestBody {
}
```

#### 定义@XxxMapping的处理器Dispatcher

DispatcherServlet内部负责从IoC容器找出所有@Controller和@RestController定义的Bean，扫描它们的方法，找出@XxxMapping标识的方法，作为处理特定URL的处理器，我们抽象为Dispatcher类

```java
public class Dispatcher {

    //是哪一种HTTP请求
    private final String httpMethod;
    // 是否是RestController
    private boolean isRest;
    // 是否有@ResponseBody:
    private boolean isResponseBody;
    // 是否返回void:
    private boolean isVoid;
    // URL正则匹配:
    private Pattern urlPattern;
    // Bean实例:
    private Object controller;
    // 处理方法:
    private Method handlerMethod;
    // 方法参数:
    private Param[] methodParameters;
}
```

Dispatcher的构造函数还没有提供，其涉及正则表达式匹配，我们在下面介绍

Dispatcher中有对参数进行解析（根据@RequestParam等注解）并注入的功能，我们把参数抽象为Param类

```java
public class Param {

    public enum ParamType {
        PATH_VARIABLE, //路径参数，从URL中提取；
        REQUEST_PARAMETER, //请求参数，从URL Query或Form表单提取
        REQUEST_BODY, //请求体，从Post传递的JSON提取
        SERVLET_VARIABLE, //HttpServletRequest等Servlet API提供的参数，直接从DispatcherServlet的方法参数获得
    }

    // 参数名称:
    public String name;
    // 参数类型:
    public ParamType paramType;
    // 参数Class类型:
    public Class<?classType;
    // 参数默认值
    public String defaultValue;

    public Param(Method method, Parameter parameter, Annotation[] annotations) {
        this.name = parameter.getName();//默认用参数名称，注解有指定就在下面修改
        this.classType = parameter.getType();
        RequestParam requestParam = ClassUtils.findAnnotation(annotations, RequestParam.class);
        RequestBody requestBody = ClassUtils.findAnnotation(annotations, RequestBody.class);
        PathVariable pathVariable = ClassUtils.findAnnotation(annotations, PathVariable.class);

        int total = 0;
        total += (requestParam == null) ? 0 : 1;
        total += (requestBody == null) ? 0 : 1;
        total += (pathVariable == null) ? 0 : 1;
        if (total 1) {
            throw new ServerErrorException(String.format("在方法%s的参数%s上发现了超过一个注解", method.getName(), parameter.getName()));
        }

        //根据注解的不同构造不同参数类型
        if (requestParam != null) {
            this.paramType = ParamType.REQUEST_PARAMETER;
            this.name = requestParam.value() != null ? requestParam.value() : this.name;
            this.defaultValue = requestParam.defaultValue();
        } else if (requestBody != null) {
            this.paramType = ParamType.REQUEST_BODY;
        } else if (pathVariable != null) {
            this.paramType = ParamType.PATH_VARIABLE;
            this.name = pathVariable.value() != null ? pathVariable.value() : this.name;
        } else {
            this.paramType = ParamType.SERVLET_VARIABLE;
            if (this.classType != HttpServletRequest.class && this.classType != HttpServletResponse.class &&
                    this.classType != HttpSession.class && this.classType != ServletContext.class) {
                throw new ServerErrorException(String.format("（可能没有注解）在方法%s中有错误的参数类型%s",method.getName(),classType.getName()));
            }
        }
    }
}
```

#### 正则表达式为@PathVarible解析url

在`Dispatcher`中的`urlPattern`字段是url的正则表达式字符串，在Spring中，url的PathVarible以大括号{}表示，这显然不是标准的正则表达式形式，因此我们要把它转换成正则表达式的形式

如何通过正则表达式从url中提取路径参数呢，我们可以使用命名捕获组捕获实际url的对应字符串，它的形式是`(?<组名>子表达式)`，也就是我们要把{}替换成命名捕获组的形式，名字应该是{}里的名字

```java
public class PathUtils {
    /**
     * 把{}形式的url匹配模式串替换为命名捕获组的正则表达式模式串
     * @param path {}形式的url匹配模式串
     * @return 命名捕获组的正则表达式模式串
     * @throws ServletException 非法的{}形式的url匹配模式串
     */
    public static Pattern compile(String path) throws ServletException {
        String regex = path.replaceAll("\\{([a-zA-Z][a-zA-Z0-9]*)\\}", "(?<$1>[^/]*)");
        if (regex.indexOf('{') >= 0 || regex.indexOf('}') >= 0) {
            //还存在{或者}，说明原始字符串存在未能成对的花括号或者嵌套花括号，不是合法的url匹配路径
            throw new ServletException("非法路径: " + path);
        }
        return Pattern.compile("^" + regex + "$");
    }
}
```

让我们解析第一个正则表达式，由于Java中`\`需要转义成`\\`，所以实际的正则表达式是`\{([a-zA-Z][a-zA-Z0-9]*)\}`

- `\{...\}`，匹配以`{`开头，`}`结尾的字符串，花括号在正则表达式中需要转义
- `(...)`，在正则表达式中`()`的内容会标记为一个捕获组，由于我们的正则表达式只有一对括号，因此这个捕获组就是第一个捕获组，也就是`{}`的内容都在第一个捕获组
- `[a-zA-Z][a-zA-Z0-9]*`，匹配第一个字符以小写或大写字母开头，随后有0-任意个字母或数字的内容

举例说明，有`/user/{id}/profile`，被这个正则表达式匹配的部分是`{id}`，其中`{}`内的内容`id`是以第一个字符以小写或大写字母开头，随后有0-任意个字母或数字的内容，匹配成功，第一个捕获组捕获到的内容是`id`

接下来解析第二个正则表达式，其用到了命名捕获组的写法`(?<$1>[^/]*)`

- `(?<$1>[^/]*)`是`(?<组名>子表达式)`的形式，也就是一个命名捕获组
- `$1`，`String.replaceAll(regex, replacement)` 的第二个参数（替换字符串）支持引用捕获组，其引用第一个参数的捕获组的内容，`$1`表示引用第一个正则表达式的第一个捕获组的内容，也就是这个$1会被替换成引用的内容
- `[^/]*`，表示匹配除了`/`外的0-任意个字符，会一直匹配到遇到第一个`/`为止

举例说明，有`/user/{id}/profile`，在前面说过第一个捕获组捕获到的内容是`id`，因此`$1`被替换成`id`，实际被替换后的字符串就是`/user/(?<id>[^/]*)/profile`

最后我们返回的regex前面加上了`^`，后面加上`$`，表示必须从字符串的开头到结尾匹配，不能只匹配中间的一段

假设实际传入的url是`/user/001/profile`，在这个`/user/(?<id>[^/]*)/profile`的正则表达式匹配下，命名捕获组id = 001，我们可以通过如下方法获取命名捕获组的内容a

```java
Pattern pattern = Pattern.compile(regex);
Matcher matcher = pattern.matcher(input);

if (matcher.matches()) {
    String id = matcher.group("id");
}
```

有了以上的正则表达式处理工具类和Param参数类，就可以写出Dispatcher的构造函数

```java
/**
 * Dispatcher的构造函数
 * @param isRest 是否返回REST:
 * @param isResponseBody 是否是ResponseBody
 * @param urlPattern url模式串，用{}标记路径参数
 * @param controller 这个方法所在的Bean实例
 * @param handlerMethod 处理对应路径的web请求的方法
 * @throws ServletException url模式串有错误
 */
public Dispatcher(String httpMethod ,boolean isRest, boolean isResponseBody, String urlPattern, Object controller, Method handlerMethod) throws ServletException {
    this.httpMethod = httpMethod;
    this.isRest = isRest;
    this.isResponseBody = isResponseBody;
    this.isVoid = handlerMethod.getReturnType() == void.class; //只要方法没有返回值就是true
    this.urlPattern = PathUtils.compile(urlPattern); //把{}替换成正则表达式命名捕获组的形式
    this.controller = controller;
    this.handlerMethod = handlerMethod;
    Parameter[] parameters = handlerMethod.getParameters();
    Annotation[][] annotations = handlerMethod.getParameterAnnotations();
    this.methodParameters = new Param[annotations.length];
    //一个个处理参数
    for (int i = 0; i < annotations.length; i++) {
        this.methodParameters[i] = new Param(handlerMethod, parameters[i], annotations[i]);
    }
    logger.atDebug().log("把url: {} 映射到了方法 {}.{}", urlPattern, controller.getClass().getName(), handlerMethod.getName());
    if (logger.isDebugEnabled()) {
        for (Param param : this.methodParameters) {
            logger.debug("> parameter : {}", param);
        }
    }
}
```

#### 操作Servlet API，完善Dispatcher的`process()`方法

正常用户在使用WebMVC的过程中，`@XxxMapping`的方法只负责Web的逻辑处理部分，从Servlet API获取参数，把返回值交给Servlet API的过程则是框架自动负责的。而我们的`Dispatcher`就应该提供这样的方法，从从Servlet API获取参数，调用`@XxxMapping`的方法，再把返回值交给Servlet API，我们需要定义这个方法`process()`

此外，由于从Servlet API拿到的请求参数都是String形式的，我们必须定义把String转换成参数指定类型方法

```java
/**
 * 把String形式的参数值转换为指定基本类型
 * @param value String形式的参数
 * @param type 要转换的基本类型
 * @return 转换结果
 */
private Object convertToType(String value, Class<?> type) {
    if (type == String.class) {
        return value;
    } else if (type == boolean.class || type == Boolean.class) {
        return Boolean.parseBoolean(value);
    } else if (type == int.class || type == Integer.class) {
        return Integer.parseInt(value);
    } else if (type == long.class || type == Long.class) {
        return Long.parseLong(value);
    } else if (type == byte.class || type == Byte.class) {
        return Byte.parseByte(value);
    } else if (type == short.class || type == Short.class) {
        return Short.parseShort(value);
    } else if (type == double.class || type == Double.class) {
        return Double.parseDouble(value);
    } else if (type == float.class || type == Float.class) {
        return Float.parseFloat(value);
    } else if (type == char.class || type == Character.class) {
        return value.charAt(0);
    } else {
        throw new ServerErrorException("无法转换参数" + value + "到指定类型" + type.getSimpleName());
    }
}
```

`@RequsetParam`可以有默认值defaultValue，创建`getParamOrDefalut()`方法，先从Servlet上查找参数值，没有再用defaultValue

```java
/**
 * 从Servlet的请求获取请求参数key的结果
 * @param key 请求参数key
 * @param request Servlet请求
 * @param defaultValue 没有对应参数时的默认值
 * @return 返回结果
 */
private String getParamOrDefault(String key, HttpServletRequest request, String defaultValue) {
    String value = request.getParameter(key);
    value = value == null ? defaultValue : value;
    if (WebUtils.DEFAULT_PARAM_VALUE.equals(value)) {
        throw new ServerWebInputException("请求参数" + key + "没有找到");
    }
    return value;
}
```

`@RequsetBody`需要从Json字符串反序列化出对象，我们创建JsonUtils提供这些工具方法，目前只需要从Json反序列化出对象的方法，之后还可以添加序列化成Json的方法

先引入Jackson的依赖，提供序列化，反序列化功能

```xml
<dependency>
    <groupId>com.fasterxml.jackson.core</groupId>
    <artifactId>jackson-databind</artifactId>
    <version>2.17.2</version>
</dependency>
```

再添加JsonUtils工具类，提供各种从Json反序列化出对象的方法

```java
public class JsonUtils {

    private static final ObjectMapper OBJECT_MAPPER;

    static {
        OBJECT_MAPPER = new ObjectMapper();
        OBJECT_MAPPER.setSerializationInclusion(JsonInclude.Include.ALWAYS);
        //关闭以下功能
        OBJECT_MAPPER.disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);
        OBJECT_MAPPER.disable(SerializationFeature.FAIL_ON_EMPTY_BEANS);
        OBJECT_MAPPER.disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
    }

    public static <T> T readJson(String json, Class<T> type) {
        try {
            return OBJECT_MAPPER.readValue(json,type);
        } catch (JsonProcessingException e) {
            throw new UncheckedIOException(e);
        }
    }

    public static <T> T readJson(Reader reader, Class<T> type) {
        try {
            return OBJECT_MAPPER.readValue(reader,type);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    public static <T> T readJson(InputStream input, Class<T> type) {
        try {
            return OBJECT_MAPPER.readValue(input,type);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    public static <T> T readJson(String json, TypeReference<T> type) {
        try {
            return OBJECT_MAPPER.readValue(json,type);
        } catch (JsonProcessingException e) {
            throw new UncheckedIOException(e);
        }
    }

    public static <T> T readJson(Reader reader, TypeReference<T> type) {
        try {
            return OBJECT_MAPPER.readValue(reader,type);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    public static <T> T readJson(InputStream input, TypeReference<T> type) {
        try {
            return OBJECT_MAPPER.readValue(input,type);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    public static Map<String, Object> readJsonToMap(String json) {
        return readJson(json, new TypeReference<HashMap<String, Object>>() {});
    }
}
```

最后完成我们的核心方法`process()`

```java
/**
 * 执行Servlet API操作，接收请求处理并返回
 * @param url 请求url
 * @param request 请求
 * @param response 响应
 * @return 响应结果
 * @throws Exception 处理请求逻辑时的异常
 */
public Result process(String url, HttpServletRequest request, HttpServletResponse response) throws Exception {
    //先正则表达式匹配url
    Matcher matcher = urlPattern.matcher(url);
    if (matcher.matches()) {
        //匹配成功

        //先解析所有的请求参数
        Object[] args = new Object[methodParameters.length];//方法调用的参数列表
        for (int i = 0; i < methodParameters.length; i++) {
            Param param = methodParameters[i];
            args[i] = switch (param.paramType) {
                case REQUEST_PARAMETER -> {
                    String value = getParamOrDefault(param.name, request, param.defaultValue);
                    yield convertToType(value,param.classType);
                }
                case REQUEST_BODY -> {
                    try {
                        BufferedReader reader = request.getReader();
                        yield JsonUtils.readJson(reader,param.classType);
                    } catch (IOException e) {
                        throw new UncheckedIOException(e);
                    }
                }
                case PATH_VARIABLE -> {
                    try {
                        String value = matcher.group(param.name);
                        yield convertToType(value, param.classType);
                    } catch (IllegalArgumentException e) {
                        throw new ServerWebInputException("路径参数" + param.name + "没有找到");
                    }
                }
                case SERVLET_VARIABLE -> {
                    Class<?> type = param.classType;
                    if (type == HttpServletRequest.class) {
                        yield request;
                    } else if (type == HttpServletResponse.class) {
                        yield response;
                    } else if (type == HttpSession.class) {
                        yield request.getSession();
                    } else if (type == ServletContext.class) {
                        yield request.getServletContext();
                    } else {
                        throw new ServerErrorException("无法确定参数" + param.name + "的类型" + type.getName());
                    }
                }
            };
        }

        //利用反射执行@XxxMapping注解的方法拿到结果并返回
        try {
            Object result = handlerMethod.invoke(controller, args);
            return new Result(true, result);
        } catch (InvocationTargetException e) {
            Throwable target = e.getTargetException();
            if (target instanceof Exception exception) {
                throw exception;
            }
            throw e;
        } catch (ReflectiveOperationException e) {
            throw new ServerErrorException(e);
        }
    } else {
        //匹配失败直接拿未处理的Result
        return NOT_PROCESSED;
    }
}
```

其中的Result是我们定义的返回结果类

```java
public record Result(boolean processed, Object result){
}

//没有处理请求
private static final Result NOT_PROCESSED = new Result(false, null);
```

#### 注册所有Dispacther

DispactherServlet需要注册并保存所有的Dispatcher，Dispatcher是提供IoC容器管理的Bean的`@Controller`类下的`@XxxMapping`标识的，因此其还要拿到IoC容器，

`resourcePath``faviconPath`用来判断url的路径是不是静态资源路径，其在配置文件中配置，因此还要拿到`PropertyResolver`，

`ViewResolver`是我们自己定义的MVC的视图处理器，我们在后面的完善Dispacther部分介绍`View``ViewResolver``ModelAndView`等我们自己定义的MVC相关的类

想一下我们为什么需要手动拿到IoC容器`ApplicationContext`，拿到`PropertyResolver`，而不是把`DispatcherServlet`标记为`@Component`后让IoC容器注入依赖？因为在Servlet标准中，Servlet和IoC容器都是Servlet Container的一部分，它们是同级别的关系，而如果让IoC管理Servlet，就不是同级别的了，没有遵守Servlet标准

```java
public class DispatcherServlet extends HttpServlet {

    private final Logger logger = LoggerFactory.getLogger(this.getClass());

    private final ApplicationContext context;

    private final ViewResolver viewResolver;

    private final String resourcePath;
    private final String faviconPath;

    List<Dispatcher> getDispatchers = new ArrayList<>();
    List<Dispatcher> postDispatchers = new ArrayList<>();
    List<Dispatcher> putDispatchers = new ArrayList<>();
    List<Dispatcher> deleteDispatchers = new ArrayList<>();

    public DispatcherServlet(ApplicationContext context, PropertyResolver propertyResolver) {
        this.context = context;
        this.viewResolver = context.getBean(ViewResolver.class); //ViewResolver已经在WebMvcConfiguration注册到IoC容器，记得@Import，这个部分我们在后面介绍
        String path = propertyResolver.getProperty("${winter.web.static-path:/static/}");
        this.faviconPath = propertyResolver.getProperty("${winter.web.favicon-path:/favicon.ico}");
        //资源路径以/结尾
        if (!path.endsWith("/")) {
            path = path + "/";
        }
        this.resourcePath = path;
    }
}
```

其的初始化过程就是在IoC容器管理的Bean找到`@Controller`注解的类下的`@XxxMapping`注解的方法的过程，我们直接扫描所有Bean找到`@Controller`注解的类，在扫描这些类的方法即可，注意的是`@RestController`组合了`@PrsponseBody`，而`isAnnotationPresent()`只能检查一层，多层注解检查依赖我们的工具类`ClassUtils`的`findAnnotation()`

```java
/**
 * 初始化所有的Controller的Mapping为Dispatcher
 * @throws ServletException 在静态方法上使用了@XxxMapping
 */
public void init() throws ServletException {
    logger.info("初始化 {}", this.getClass().getName());
    List<BeanDefinition> allBeans = ((ConfigurableApplicationContext) context).findBeanDefinitions(Object.class);
    for (BeanDefinition beanDefinition : allBeans) {
        Class<?> beanClass = beanDefinition.getBeanClass();
        Controller controller = beanClass.getAnnotation(Controller.class);
        RestController restController = beanClass.getAnnotation(RestController.class);
        if (controller != null && restController != null) {
            throw new ServletException("在类" + this.getClass().getName() + "上同时发现了@Controller和@RestController注解");
        }
        Object bean = beanDefinition.getInstance();
        if (controller != null) {
            addController(false, beanDefinition.getName(), bean);
        }
        if (restController != null) {
            addController(true, beanDefinition.getName(), bean);
        }
    }
}

@Override
public void destroy() {
    this.context.close();
}

/**
 * 添加bean所有@XxxMapping注解的方法为Dispatcher
 * @param isRest 是否是@RestController
 * @param name bean名称
 * @param bean 方法所在的bean实例
 * @throws ServletException 在静态方法上使用了@XxxMapping
 */
private void addController(boolean isRest, String name, Object bean) throws ServletException {
    logger.info("添加了{} controller : {}", isRest ? "REST" : "MVC", name);
    addMappings(isRest,bean,bean.getClass());
}

/**
 * 添加beanClass类型下所有@XxxMapping注解的方法为Dispatcher
 * @param isRest 是否是@RestController
 * @param bean 方法所在的bean实例
 * @param beanClass 类型，可以是bean自己的类型或其父类
 * @throws ServletException 在静态方法上使用了@XxxMapping
 */
private void addMappings(boolean isRest, Object bean, Class<?> beanClass) throws ServletException {
    //注册Bean的所有被@XxxMapping注解的方法
    for (Method method : beanClass.getDeclaredMethods()) {
        //只要方法有对应注解就是true
        //另外，如果Bean上直接有@ResponseBody，所有方法都是true
        boolean isResponseBody = method.isAnnotationPresent(ResponseBody.class) || (ClassUtils.findAnnotation(beanClass, ResponseBody.class) != null); //isAnnotationPresent()只能检查一层，多层注解检查依赖我们的工具类
        if (method.isAnnotationPresent(GetMapping.class)) {
            checkMappings(method);
            String url = method.getAnnotation(GetMapping.class).value();
            getDispatchers.add(new Dispatcher("GET",isRest,isResponseBody,url,bean,method));
        } else if (method.isAnnotationPresent(PostMapping.class)) {
            checkMappings(method);
            String url = method.getAnnotation(PostMapping.class).value();
            postDispatchers.add(new Dispatcher("POST",isRest,isResponseBody,url,bean,method));
        } else if (method.isAnnotationPresent(PutMapping.class)) {
            checkMappings(method);
            String url = method.getAnnotation(PutMapping.class).value();
            putDispatchers.add(new Dispatcher("PUT",isRest,isResponseBody,url,bean,method));
        } else if (method.isAnnotationPresent(DeleteMapping.class)) {
            checkMappings(method);
            String url = method.getAnnotation(DeleteMapping.class).value();
            deleteDispatchers.add(new Dispatcher("DELETE",isRest,isResponseBody,url,bean,method));
        }
    }
    Class<?> superClass = beanClass.getSuperclass();
    if (superClass != null) {
        addMappings(isRest,bean,superClass);
    }
}

/**
 * 检查是否是静态方法
 * @param method 要检查的方法
 * @throws ServletException 是静态方法
 */
private void checkMappings(Method method) throws ServletException {
    if (Modifier.isStatic(method.getModifiers())) {
        throw new ServletException("不可以在静态方法上添加URL映射");
    }
    method.setAccessible(true);
}
```

#### 完善DispactherServlet

##### 处理动态请求--把请求交给Dispatcher处理

Dispatcher处理完的结果是Result，其的`isProcessed()`用于获取是否对其进行处理，如果这个Dispatcher和url不匹配结果就是false，匹配是就返回结果

Dispatcher处理后返回类型包括：

- void或null：表示内部已处理完毕；
- String：如果以redirect:开头，则表示一个重定向；
- String或byte[]：如果配合@ResponseBody，则表示返回值直接写入响应；
- ModelAndView：表示这是一个MVC响应，包含Model和View名称，后续用模板引擎处理后写入响应；
- 其它类型：如果是@RestController或者@ResponseBody，则序列化为JSON后写入响应。

REST模式下，@ResponseBody或者@RestController需要直接写入响应，我们需要序列化到Json的方法，在JsonUtils添加以下方法

```java
public static String writeJson(Object obj) {
    try {
        return OBJECT_MAPPER.writeValueAsString(obj);
    } catch (JsonProcessingException e) {
        throw new UncheckedIOException(e);
    }
}

public static void writeJson(Writer writer, Object obj) {
    try {
        OBJECT_MAPPER.writeValue(writer,obj);
    } catch (IOException e) {
        throw new UncheckedIOException(e);
    }
}

public static void writeJson(OutputStream out, Object obj) {
    try {
        OBJECT_MAPPER.writeValue(out,obj);
    } catch (IOException e) {
        throw new UncheckedIOException(e);
    }
}
```

MVC模式下，我们定义视图类接口（View），视图和模式类（ViewAndModel），提供渲染视图的方法`render()`

```java
public interface View {

    default String getContentType() {
        return null;
    }

    void render(@Nullable Map<String, Object> model, HttpServletRequest request, HttpServletResponse response) throws IOException;
}

public class ModelAndView {

    private final String viewName;
    private final Map<String, Object> model = new HashMap<>();
    private final int status;

    public ModelAndView(String viewName, @Nullable Map<String, Object> model, int status) {
        this.viewName = viewName;
        if (model != null) {
            this.model.putAll(model);
        }
        this.status = status;
    }
    public ModelAndView(String viewName, @Nullable Map<String, Object> model) {
        this.viewName = viewName;
        if (model != null) {
            this.model.putAll(model);
        }
        this.status = HttpServletResponse.SC_OK;
    }
    public ModelAndView(String viewName) {
        this.viewName = viewName;
        this.status = HttpServletResponse.SC_OK;
    }

    public String getViewName() {
        return this.viewName;
    }

    public int getStatus() {
        return this.status;
    }

    public Map<String, Object> getModel() {
        return this.model;
    }

    public void addModel(String key, Object value) {
        this.model.put(key, value);
    }

    public void addModel(Map<String, Object> model) {
        this.model.putAll(model);
    }
}
```

还需要定义视图处理类

```java
public interface ViewResolver {
    // 初始化ViewResolver:
    void init();
    // 渲染:
    void render(String viewName, Map<String, Object> model, HttpServletRequest request, HttpServletResponse response);
}
```

Spring内置FreeMarker引擎处理MVC，我们也采用这种方案实现视图处理类，完成MVC处理

引入依赖，由于Servlet新版本的包名不同，必须使用2.3.33+版本

```xml
<dependency>
  <groupId>org.freemarker</groupId>
  <artifactId>freemarker</artifactId>
  <version>2.3.34</version>
</dependency>
```

然后设计我们的`FreeMarkViewResolver`，核心是

- 初始化FreeMark的Configuration，从路径和ServletContext加载资源
- 提供渲染的`render()`方法，通过viewName获取视图Template，再调用这个Template在的`process()`方法通过提供的model渲染视图并写入响应

```java
/**
 * 使用FreeMark的视图处理器
 */
public class FreeMarkViewResolver implements ViewResolver {

    private final String templatePath;
    private final String templateEncoding;
    private final ServletContext servletContext;
    private Configuration configuration;

    public FreeMarkViewResolver(String templatePath, String templateEncoding, ServletContext servletContext) {
        this.templatePath = templatePath;
        this.templateEncoding = templateEncoding;
        this.servletContext = servletContext;
        init(); //手动在构造函数初始化
    }

    /**
     * 初始化configuration
     */
    @Override
    public void init() {
        Configuration cfg = new Configuration(Configuration.VERSION_2_3_23);
        cfg.setOutputFormat(HTMLOutputFormat.INSTANCE);
        cfg.setDefaultEncoding(this.templateEncoding);
        cfg.setTemplateLoader(new WebappTemplateLoader(this.servletContext, this.templatePath));
        cfg.setTemplateExceptionHandler(TemplateExceptionHandler.HTML_DEBUG_HANDLER);
        cfg.setAutoEscapingPolicy(Configuration.ENABLE_IF_SUPPORTED_AUTO_ESCAPING_POLICY);
        cfg.setLocalizedLookup(false);
        DefaultObjectWrapper objectWrapper = new DefaultObjectWrapper(Configuration.VERSION_2_3_23);
        objectWrapper.setExposeFields(true);
        cfg.setObjectWrapper(objectWrapper);
        this.configuration = cfg;
    }

    /**
     * 渲染
     * @param viewName 视图名称
     * @param model 模式
     * @param request 请求
     * @param response 响应
     * @throws IOException 写入响应输出流异常
     */
    @Override
    public void render(String viewName, Map<String, Object> model, HttpServletRequest request, HttpServletResponse response) throws IOException {
        Template template;
        try {
            template = configuration.getTemplate(viewName);
        } catch (IOException e) {
            throw new ServerErrorException("没有找到View:" + viewName, e);
        }
        PrintWriter writer = response.getWriter();
        try {
            template.process(model, writer);//渲染好的视图直接写入输出流
        } catch (TemplateException e) {
            throw new ServerErrorException(e);
        }
        writer.flush();
    }
}
```

其中的`WebappTemplateLoader`记得其全限定名是`freemarker.ext.jakarta.servlet.WebappTemplateLoader`，老版本的这个类在新版本仍然存在但是包不同，它们的区别是Servlet的包名由`javax`变为`jakarta`导致的

定义这些MVC的相关类，就可以在DispatcherServlet内部，把处理ModelAndView和ViewResolver结合起来，最终向HttpServletResponse中输出HTML，完成HTTP请求的处理

对于ViewResolver视图处理类，如果我们每次需要时都new一个非常不方便，不妨直接交给IoC容器管理，参数就从配置文件或者IoC容器获取，同理我们也把ServletContext交给IoC容器

```java
@Configuration
public class WebMvcConfiguration {

    private static ServletContext servletContext;
    public static void setServletContext(ServletContext servletContext) {
        WebMvcConfiguration.servletContext = servletContext;
    }

    @Bean
    public ServletContext servletContext() {
        return Objects.requireNonNull(servletContext, "ServletContext没有被设置");
    }

    @Bean
    public ViewResolver viewResolver(
            @Autowired ServletContext servletContext,
            @Value("${winter.web.freemarker.template-path:/WEB-INF/templates}") String templatePath,
            @Value("${winter.web.freemarker.template-encoding:UTF-8}") String templateEncoding
    ) {
        return new FreeMarkViewResolver(templatePath,templateEncoding,servletContext);
    }
}
```

最后，就可以完善我们的动态请求处理方法`doService()`

注意的是响应`response`在每个阶段都可以被写入，而ContentType等响应头只需要设置一次，因此在`setContentType()`时必须判断前面的步骤是否已经写入并发送了HTTP Header

```java
if(!response.isCommitted()) {
    response.setContentType("application/json");
}
```

```java
/**
 * 处理动态请求
 * @param request 请求
 * @param response 响应
 * @param dispatchers Web请求处理器集合
 * @throws Exception Web请求处理异常
 */
private void doService(HttpServletRequest request, HttpServletResponse response, List<Dispatcher> dispatchers) throws Exception {
    String url = request.getRequestURI();
    for (Dispatcher dispatcher : dispatchers) {
        Dispatcher.Result result = dispatcher.process(url,request,response);
        if (result.processed()) {
            Object returnObject = result.result();
            if (returnObject == null && dispatcher.isVoid()) {
                return;//空响应
            }

            if (dispatcher.isRest()) {
                //是RestController，处理REST
                if(!response.isCommitted()) {
                    response.setContentType("application/json");
                }
                if (dispatcher.isResponseBody()) {
                    //是ResponseBody，在这个if是一定是true的
                    writeToResponseDirectly(returnObject, response);
                }
                //不存在是@RestController且不是@ResponseBody的情况
            } else {
                //只是Controller
                if (!response.isCommitted()) {
                    response.setContentType("text/html");
                }
                if (dispatcher.isResponseBody()) {
                    writeToResponseDirectly(returnObject, response);
                    return;
                }
                //没有@ResponseBody，可能是重定向（redirect:开头的String）或者MVC响应
                if (returnObject instanceof String s && s.startsWith("redirect:")) {
                    //普通重定向
                    response.setStatus(HttpServletResponse.SC_MOVED_TEMPORARILY);
                    response.sendRedirect(s.substring("redirect:".length()));
                } else if (returnObject instanceof ModelAndView mv) {
                    //MVC处理
                    String viewName = mv.getViewName();
                    if (viewName.startsWith("redirect:")) {
                        //MVC重定向
                        response.setStatus(HttpServletResponse.SC_MOVED_TEMPORARILY);
                        response.sendRedirect(viewName.substring("redirect:".length()));
                    } else {
                        this.viewResolver.render(viewName, mv.getModel(), request, response);
                    }
                } else if (!dispatcher.isVoid() && returnObject != null) {
                    //返回值不是我们能处理的任何一种情况，抛出异常
                    throw new ServletException("无法处理" + returnObject.getClass().getName() + "，url请求为: " + url);
                }
            }

            //只要找到了Dispatcher处理了，就直接返回
            return;
        }
    }
    //没有任何Dispatcher处理，设置404
    response.setStatus(HttpServletResponse.SC_NOT_FOUND);
}
```

`HttpServlet`的`doGet()`等方法只允许抛出`ServletException, IOException`，我们当前的`doService()`抛出`Exception`，不符合要求，不方便在`doGet()`等方法调用，我们包装一个`doServiceHandleException()`，在其中只进行异常处理，保证抛出的异常符合`ServletException, IOException`

```java
/**
 * 包装动态请求doService()方法，只进行异常处理，保证抛出异常符合HttpServlet的doXxx方法
 * @param request 请求
 * @param response 响应
 */
private void doServiceHandleException(HttpServletRequest request, HttpServletResponse response, List<Dispatcher> dispatchers) throws ServletException, IOException {
    String url = request.getRequestURI();
    try {
        doService(request,response,dispatchers);
    } catch (ErrorResponseException e) {
        logger.warn("处理url: " + url + "的请求异常，错误代码: " + e.statusCode, e);
        if (!response.isCommitted()) {
                response.resetBuffer();
                response.sendError(e.statusCode);
        }
    } catch (RuntimeException | ServletException | IOException e) {
        logger.warn("处理url: " + url + "的请求异常");
        throw e;
    } catch (Exception e) {
        logger.warn("处理url: " + url + "的请求异常");
        throw new NestedRuntimeException(e);
    }
}
```

##### 处理静态请求

静态资源的处理要简单不少，直接根据url，通过请求的`ServletContext`从url获取资源输入流，再把输入流写入响应的输出流即可

```java
/**
 * 处理静态资源
 * @param url 静态资源路径
 * @param request 请求
 * @param response 响应
 */
private void doResource(String url ,HttpServletRequest request, HttpServletResponse response) {
    ServletContext servletContext = request.getServletContext();
    //从路径获取静态资源输入流
    try (InputStream input = servletContext.getResourceAsStream(url)) {
        if (input == null) {
            response.setStatus(HttpServletResponse.SC_NOT_FOUND);
        } else {
            String file = url;
            int n = file.lastIndexOf("/")
            if (n >= 0) {
                file = file.substring(n + 1);
            }
            String mime = servletContext.getMimeType(file);
            if (mime == null) {
                //兜底输出类型
                mime = "application/octet-stream";
            }
            //设置输出类型
            response.setContentType(mime);
            //直接把输入流写到输出流
            OutputStream output = response.getOutputStream();
            input.transferTo(output);
            output.flush();
        }
    } catch (IOException e) {
        throw new UncheckedIOException(e);
    }
}
```

##### 完成`HttpServlet`要求的`doGet()`，`doPost()`等方法

只有GET请求可能是静态请求，前面在DispactherServlet中从配置文件读取的`faviconPath`和`resourcePath`就是在这里用来判断是否是静态请求的

```java
@Override
protected void doGet(HttpServletRequest request, HttpServletResponse response) throws ServletException, IOException {
    String url = request.getRequestURI();
    if (url.equals(faviconPath) || url.startsWith(resourcePath)) {
        doResource(url,request,response);
    } else {
        doServiceHandleException(request,response,getDispatchers);
    }
}
```

POST，PUT，DELETE都是动态请求，只需要调用动态请求的方法

```java
@Override
protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
    doServiceHandleException(req,resp,postDispatchers);
}

@Override
protected void doPut(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
    doServiceHandleException(req,resp,putDispatchers);
}

@Override
protected void doDelete(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
    doServiceHandleException(req,resp,deleteDispatchers);
}
```

#### 实现过滤器Filter

我们定义一个Filter的Bean的抽象类，用户需要定义自己的过滤器时继承这个类

```java
public abstract class FilterRegistrationBean {

    public abstract List<String> getUrlPatterns();

    /**
     * 首字母小写，去除FilterRegistrationBean，FilterRegistration后缀
     * @return Filter名字
     */
    public String getName() {
        String name = getClass().getName();
        if (name.endsWith("FilterRegistrationBean") && name.length() > "FilterRegistrationBean".length()) {
            name = name.substring(0, name.length() - "FilterRegistrationBean".length());
        }
        if (name.endsWith("FilterRegistration") && name.length() > "FilterRegistration".length()) {
            name = name.substring(0, name.length() - "FilterRegistration".length());
        }
        return Character.toLowerCase(name.charAt(0)) + name.substring(1);
    }

    public abstract Filter getFilter();
}
```

然后在ContextLoaderListener里的ServletContext注册Filter，Filter是有IoC容器管理的，直接从IoC取出即可

```java
//注册所有的Filter
List<FilterRegistrationBean> filters = applicationContext.getBeans(FilterRegistrationBean.class);
for (FilterRegistrationBean filterBean : filters) {
    String name = filterBean.getName();
    List<String> urlPatterns = filterBean.getUrlPatterns();
    if (urlPatterns == null || urlPatterns.isEmpty()) {
        throw new IllegalStateException("过滤器" + name + "的urlPatterns为空");
    }
    Filter filter = Objects.requireNonNull(filterBean.getFilter(), "过滤器的Bean获取Filter的方法返回了null");
    FilterRegistration.Dynamic filterRegistration = servletContext.addFilter(name, filter);//注册到ServletContext
    filterRegistration.addMappingForUrlPatterns(EnumSet.of(DispatcherType.REQUEST), true, urlPatterns.toArray(String[]::new));
    logger.info("为url: {} 注册了过滤器 {}:{}",urlPatterns , name, filterBean.getClass().getName());
}
```

#### 完善ContextLoaderListener

完善ContextLoaderListener的初始化方法

```java
@Override
public void contextInitialized(ServletContextEvent sce) {
    logger.info("初始化{}", getClass().getName());
    ServletContext servletContext = sce.getServletContext();

    //设置配置类的ServletContext属性
    WebMvcConfiguration.setServletContext(servletContext);

    //创建IoC容器和PropertyResolver
    PropertyResolver propertyResolver = WebUtils.createPropertyResolver();
    ApplicationContext applicationContext = new AnnotationConfigApplicationContext(
            getApplicationContextClass(servletContext.getInitParameter("configuration")),
            propertyResolver
    );

    //设置ServletContext的字符串编码
    String encoding = propertyResolver.getProperty("${winter.web.character-encoding:UTF-8}");
    servletContext.setRequestCharacterEncoding(encoding);
    servletContext.setResponseCharacterEncoding(encoding);
    
    //注册所有的Filter
    List<FilterRegistrationBean> filters = applicationContext.getBeans(FilterRegistrationBean.class);
    for (FilterRegistrationBean filterBean : filters) {
        String name = filterBean.getName();
        List<String> urlPatterns = filterBean.getUrlPatterns();
        if (urlPatterns == null || urlPatterns.isEmpty()) {
            throw new IllegalStateException("过滤器" + name + "的urlPatterns为空");
        }
        Filter filter = Objects.requireNonNull(filterBean.getFilter(), "过滤器的Bean获取Filter的方法返回了null");
        FilterRegistration.Dynamic filterRegistration = servletContext.addFilter(name, filter);//注册到ServletContext
        filterRegistration.addMappingForUrlPatterns(EnumSet.of(DispatcherType.REQUEST), true, urlPatterns.toArray(String[]::new));
        logger.info("为url: {} 注册了过滤器 {}:{}",urlPatterns , name, filterBean.getClass().getName());
    }

    //注册DispatcherServlet
    DispatcherServlet dispatcherServlet = new DispatcherServlet(applicationContext,propertyResolver);
    ServletRegistration.Dynamic servletRegistration = servletContext.addServlet("dispatcherServlet", dispatcherServlet);
    servletRegistration.addMapping("/");
    servletRegistration.setLoadOnStartup(0);

    servletContext.setAttribute("applicationContext", applicationContext);
}
```

### 小结

启动Web服务时，Servlet容器会读取web.xml，根据配置的Listener启动ContextLoaderListener，又读取web.xml配置的`<context-param>`获得配置类的全名`com.myproject.hello.HelloApplication`（这里是自己配置的），最后用这个配置类完成IoC容器的创建。创建后自动注册DispatcherServlet，以及Web应用程序定义的FilterRegistrationBean，这样就完成了整个Web应用程序的初始化

在整个HTTP处理流程中，入口是DispatcherServlet的service()方法，这个方法我们没有定义，直接继承HttpServlet的service()方法即可，我们只需要重写其会调用的doXxx()方法

整个流程如下：

1. Servlet容器调用DispatcherServlet的service()方法处理HTTP请求
2. service()根据GET或POST等调用doGet()或doPost()等方法
3. 根据请求的URL判断是静态还是动态资源
    - 是静态资源
        - 符合静态目录（默认/static/）则读取文件，写入文件内容
        - 网站图标（默认/favicon.ico）则读取.ico文件，写入文件内容
    - 是动态资源，根据URL依次匹配Dispatcher，匹配后调用process()方法，获得返回值
4. 根据返回值写入响应：
    - 静态资源直接写入
    - void或null返回值无需写入响应
    - String或byte[]返回值直接写入响应（或重定向）
    - REST类型写入JSON序列化结果
    - ModelAndView类型调用ViewResolver写入渲染结果
    - 其他情况返回404

## 构建Web应用

其实我们几乎已经完成了所有的部分，现在已经可以利用我们写的框架构建Web应用了

首先，我们在src/main/resources下定义配置文件application.yaml，配置项目名称和数据库连接信息

```yaml
app:
  title: Hello Application
  version: 1.0

winter:
  datasource:
    url: jdbc:mysql://localhost:3306/winter_db
    driver-class-name: com.mysql.cj.jdbc.Driver
    username: root
    password: xxxxxx
```

配置我们的启动类`HelloApplication`，用到JDBC和WebMVC，@Import相关配置类，我们不需要添加任何内容，因为IoC容器通过`web.xml`配置的初始listener：`ContextLoaderListener`启动的，`web.xml`中配置了启动类的全名，记得我们在`ContextLoaderListener`将启动类的名字这个属性配置为`configuration`，要在`<context-param>`配置

```java
@ComponentScan
@Import({ JdbcConfiguration.class, WebMvcConfiguration.class })
public class HelloApplication {
}
```

Service、Controller等Bean自行准备

在src/main/webapp/WEB-INF目录下创建Servlet容器所需的配置文件web.xml

```xml
<?xml version="1.0" encoding="UTF-8"?>
<web-app ...>
    <display-name>Hello Webapp</display-name>

    <context-param>
        <param-name>configuration</param-name>
        <param-value>com.myproject.hello.HelloApplication</param-value>
    </context-param>

    <listener>
        <listener-class>com.winter.web.listener.ContextLoaderListener</listener-class>
    </listener>
</web-app>
```

其它的资源目录有

- 存储在src/main/webapp/static目录下的静态资源；
- 存储于src/main/webapp/favicon.ico的图标文件；
- 存储在src/main/webapp/WEB-INF/templates目录下的模板

运行mvn clean package命令，在target目录得到编译好的war包，改名为ROOT.war，复制到Tomcat的webapps目录下，启动Tomcat，可以正常访问<http://localhost:8080>（这里是你在tomcat配置的端口），完成Web应用的构建
