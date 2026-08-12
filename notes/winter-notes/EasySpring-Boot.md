# EasySpring

Spring没有内嵌Tomcat，开发Spring的过程涉及到先打war包，再复制到Tomcat的webapps目录，再启动Tomcat

Maven提供了Tomcat的插件，向项目内嵌一个Tomcat

```xml
<plugin>
    <groupId>org.apache.tomcat.maven</groupId>
    <artifactId>tomcat7-maven-plugin</artifactId>
    <version>2.1</version>
    <configuration>
        <port>80</port>
        <path>/</path>
        <uriEncoding>UTF-8</uriEncoding><!--访问路径编解码字符集-->
    </configuration>
</plugin>
```

运行`mvn tomcat7:run`，启动了一个小型 Tomcat 服务器，并把 Web 项目临时“挂载”到这个服务器里，不需要外部安装的 Tomcat，这种内嵌Tomcat的方法被借鉴用于SpringBoot

SpringBoot内嵌了Tomcat，构建好的应用程序可以直接允许，不依赖外部的Tomcat服务器

当然，SpringBoot还提供了自动配置，starter 依赖等方便的功能

我们也实现Boot的内嵌Tomcat功能，方便项目的部署，只需要一个Jar包就能运行

## Boot

SpringBoot实现一个jar包直接运行，是把Tomcat打包进去，自己再写个main()函数

```java
@SpringBootApplication
public class AppConfig {
    public static void main(String[] args) {
        SpringApplication.run(AppConfig.class, args);
    }
}
```

我们仿造这种形式，在`WinterApplication`也提供一个`run()`方法

```java
private static final String DEFAULT_WEB_DIR = "src/main/webapp";
private static final String DEFAULT_BASE_DIR = "target/classes";

public static void run(Class<?> configClass, String[] args) {
    WinterApplication.run(DEFAULT_WEB_DIR, DEFAULT_BASE_DIR, configClass, args);
}

public static void run(String webDir, String baseDir, Class<?> configClass, String[] args) {
    PropertyResolver propertyResolver = WebUtils.createPropertyResolver();
    Server server = startTomcat(webDir, baseDir, configClass, propertyResolver);

    //启动服务器后等待服务器结束，服务器没有结束前线程一直执行
    server.await();
}
```

`startTomcat()`是启动嵌入式Tomcat的方法

```java
private static Server startTomcat(String webDir, String baseDir, Class<?> configClass, PropertyResolver propertyResolver) {
    //从配置文件查找端口
    int port = propertyResolver.getProperty("${server.port:8080}", int.class);

    Tomcat tomcat = new Tomcat();
    tomcat.setPort(port);
    tomcat.getConnector().setThrowOnFailure(true);

    //添加默认的Web应用程序，挂载在/下，设置应用程序目录
    Context context = tomcat.addWebapp("", new File(webDir).getAbsolutePath()); //记得通过File类把相对路径转化成绝对路径
    WebResourceRoot resources = new StandardRoot(context);
    resources.addPreResources(new DirResourceSet(resources, "/WEB-INF/classes", new File(baseDir).getAbsolutePath(), "/"));
    context.setResources(resources);

    //设置自己定义的初始化器，初始化ServletContext环境
    context.addServletContainerInitializer(new ContextLoaderInitializer(configClass, propertyResolver), Set.of());

    //记得启动
    try {
        tomcat.start();
    } catch (LifecycleException e) {
        throw new NestedRuntimeException("Tomcat服务启动失败",e);
    }
    logger.info("服务在端口: {}上启动了", port);

    return tomcat.getServer();
}
```

其中的`new ContextLoaderInitializer(configClass, propertyResolver)`，把我们新建的初始器添加进去，这个初始化器的写法和之前的`ContextLoaderListener`类似，为了方便，我们将`ContextLoaderListener`构造函数的注册Filter和注册Dispatcher的逻辑抽取到`WebUtils`里

```java
/**
 * 注册DispatcherServlet到ServletContext
 * @param propertyResolver 属性解决器
 * @param servletContext Tomcat的ServletContext
 */
public static void registerDispatcherServlet(PropertyResolver propertyResolver, ServletContext servletContext) {
    ApplicationContext applicationContext = ApplicationContextUtils.getRequiredApplicationContext();
    DispatcherServlet dispatcherServlet = new DispatcherServlet(applicationContext, propertyResolver);
    ServletRegistration.Dynamic servletRegistration = servletContext.addServlet("dispatcherServlet", dispatcherServlet);
    servletRegistration.addMapping("/");
    servletRegistration.setLoadOnStartup(0);
}

/**
 * 注册IoC的所有Filter到ServletContext
 * @param servletContext Tomcat的ServletContext
 */
public static void registerFilters(ServletContext servletContext) {
    ApplicationContext applicationContext = ApplicationContextUtils.getRequiredApplicationContext();
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
}
```

在我们的`ContextLoaderInitializer`里，就可以调用这两个方法，仿造`ContextLoaderListener`完成`onStartUp()`方法，这是从`ServletContainerInitializer`实现的方法，会在环境启动的时候调用

```java
public class ContextLoaderInitializer implements ServletContainerInitializer {

    private final Class<?> configClass;
    private final PropertyResolver propertyResolver;

    public ContextLoaderInitializer(Class<?> configClass, PropertyResolver propertyResolver) {
        this.configClass = configClass;
        this.propertyResolver = propertyResolver;
    }

    @Override
    public void onStartup(Set<Class<?>> set, ServletContext servletContext) throws ServletException {
        //设置配置类的ServletContext属性
        WebMvcConfiguration.setServletContext(servletContext);

        //创建IoC容器
        ApplicationContext applicationContext = new AnnotationConfigApplicationContext(this.configClass, this.propertyResolver);

        //设置ServletContext的字符串编码
        String encoding = propertyResolver.getProperty("${winter.web.character-encoding:UTF-8}");
        servletContext.setRequestCharacterEncoding(encoding);
        servletContext.setResponseCharacterEncoding(encoding);
        
        //注册所有的Filter
        WebUtils.registerFilters(servletContext);

        //注册DispatcherServlet
        WebUtils.registerDispatcherServlet(propertyResolver, servletContext);

        servletContext.setAttribute("applicationContext", applicationContext);
    }
}
```

内嵌的Tomcat只需要这两个组件

- WinterApplication：启动嵌入式Tomcat；
- ContextLoaderInitializer：启动IoC容器，注册Filter与DispatcherServlet
