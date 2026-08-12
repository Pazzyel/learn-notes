# EasySpring

## 实现AOP

AOP的实现，我们选择最简便的方案，在运行期实现AOP

主要的方式有两种

- JDK动态代理：Java的Proxy类提供的动态代理，在运行期生成代理的Java对象，要求被代理对象必须实现接口，只能对接口代理
- CGLIB字节码代理，通过动态生成字节码，可以对具体Java类实现代理

Spring的代理是多种的，一个Bean声明类型（BeanDefinition里的类型）是接口就用JDK动态代理，是普通Java类就有CGLIB字节码代理

由于CGLIB字节码代理可用的情况更多，我们选择这种方案。不过注意CGLIB目前已经不维护了，Github上的项目readme里推荐使用Byte Buddy等

让用户定义代理的形式也是多种的

- 用AspectJ的语法来定义AOP，比如execution(public * com.project.service.*.*(..))；
- 用注解来定义AOP，比如用@Transactional表示事务

大部分情况下一般直接使用注解定义AOP，因此我们细究注解定义的实现方法

### ProxyResolver

如何在IoC容器中实现一个动态代理？

在IoC容器中，实现动态代理需要用户提供两个Bean

- 原始Bean，即需要被代理的Bean；
- 拦截器，即拦截了目标Bean的方法后，会自动调用拦截器实现代理功能

然后ProxyResolver动态生成Proxy类，把被拦截的方法调用转移到Proxy类上

拦截器需要定义接口，直接用Java标准库的InvocationHandler

在Byte Buddy官网介绍页面就有使用其创建字节码的示例，我们依照这个示例写下生成代理类的方法

1. **请注意，Byte Buddy生成的代理类会重写`equals()`,代理类判断和原始类是否相同时会返回true**
2. **请注意，使用下面的逻辑生成代理类时，原始类必须有无参构造函数**

```java
public class ProxyResolver {

    private ByteBuddy byteBuddy = new ByteBuddy();

    /**
     * 动态创建代理类
     * @param beanInstance 被代理的原始Bean实例
     * @param handler 动态代理的拦截器，包含代理类需要执行的逻辑
     * @return 生成的代理类
     */
    public <T> T createProxy(Object beanInstance, InvocationHandler handler) {
        Class<?> originalClass = beanInstance.getClass();
        //生成代理类字节码class文件
        Class<?> proxyClass = byteBuddy
                .subclass(originalClass, ConstructorStrategy.Default.DEFAULT_CONSTRUCTOR) // 代理类有原始类的子类，子类实例化默认调用无参构造器
                .method(ElementMatchers.isPublic()) // 只拦截public方法
                .intercept(InvocationHandlerAdapter.of((proxy, method, args) ->
                        method.invoke(beanInstance, proxy, args))) // 执行具体拦截器逻辑
                .make() // 生成字节码
                .load(originalClass.getClassLoader()) // 加载字节码
                .getLoaded();
        //创建代理类实例
        Object proxyInstance;
        try {
            proxyInstance = proxyClass.getConstructor().newInstance();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
        return (T) proxyInstance;
    }
}
```

逐行解释

1. 用 ByteBuddy 生成一个类，它是 originalClass 的子类。使用默认的无参构造器，如果原始类没有无参构造器就会抛出异常
2. 只拦截 public 方法，其他方法（private/protected/final）不会被代理
3. 定义拦截逻辑：当调用代理对象的方法时，会转发到 InvocationHandler.invoke。这里特意写成 handler.invoke(beanInstance, method, args)，意味着：调用逻辑依然作用在原始对象 beanInstance 上，而不是代理对象自己
4. 生成并加载字节码得到可用的代理类

最为关键的部分就是`intercept(InvocationHandlerAdapter.of((proxy, method, args) -> method.invoke(beanInstance, proxy, args)))`，其中的`intercept()`方法接收一个`InvocationHandlerAdapter`对象用于向代理的类添加拦截器，`InvocationHandlerAdapter.of()`用于把Java的`InvocationHandler`类包装成`InvocationHandlerAdapter`对象

为什么不直接`InvocationHandlerAdapter.of(handler)`呢，因为如果这样，`(proxy, method, args)`这组参数会直接用在`handler`的`invoke()`方法，但是我们是向Byte Buddy生成的类添加拦截器，因此`proxy`是Byte Buddy生成的代理类本身而不是原始类，但是我们的`handler`是针对原始类进行处理的

所以，我们改成lambda实现一个新的`InvocationHandler`，也就是`(proxy, method, args) -> method.invoke(beanInstance, proxy, args)`，其无视了Byte Buddy生成的代理类`proxy`，而是直接在原始类`beanInstance`上执行`method`方法

这里的`method`其实是Byte Buddy生成的代理类的`Method`对象，因为Byte Buddy生成的代理类是原始类的子类且我们的流程也没有添加任何新的方法，因此直接调用代理类的`method`即可。**Java反射的`method.invoke(obj,args)`方法会自动找到`obj`的类型上的相同签名的方法并调用，因此这样是可行的，但是可读性不太好**

如果想要更可读的写法，我们可以把lambda改成下列形式，手动找到原始类的方法

```java
(proxy, method, args) -> {
    Method originMethod = originalClass.getMethod(method.getName(), method.getParameterTypes());
    handler.invoke(beanInstance,originMethod,args);
}
```

使用时，我们要将代理需要执行的逻辑写成一个实现InvocationHandler接口的类，并将其作为handler参数传入，需要注意的是handler只是一个拦截器，实际起到AOP作用的是通过Byte Buddy动态生成的字节码对象，其通过这个拦截器拦截原始对象调用并执行代理逻辑

例如，这是一个在控制台打印方法执行时间的handler，作为参数传入`createProxy()`

```java
public class TimeHandler implements InvocationHandler {
    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        Long before = System.currentTimeMillis();
        Object ret = method.invoke(proxy, args);
        Long after = System.currentTimeMillis();
        System.out.println("方法调用耗时" + (after - before) + "ms");
        return ret;
    }
}
```

### 完成AOP的Around，Before，After等

使用`@Around("xxx")`标注被代理类的handler的Bean名称，只有指定`@Around`的才会被代理

在装配IoC时，我们需要的Bean实例应该是代理类，这里就要用到我们在之前IoC容器的开发过程中定义的`BeanPostProcessor`，我们编写一个继承它的子类`AroundProxyBeanPostProcessor`

```java
public class AroundProxyBeanPostProcessor implements BeanPostProcessor {

    private final Map<String,Object> originBeans = new HashMap<>();

    private final ProxyResolver proxyResolver = new ProxyResolver();

    @Override
    public Object postProcessBeforeInitialization(Object bean, String beanName) {
        //获取@Around注解
        Around around = bean.getClass().getAnnotation(Around.class);
        if (around != null) {
            String handlerName;
            try {
                handlerName = (String) around.annotationType().getMethod("value").invoke(around);
            } catch (ReflectiveOperationException e) {
                throw new AopConfigException(e);
            }
            originBeans.put(beanName, bean);
            return createProxy(bean, handlerName);
        } else {
            return bean;
        }
    }

    /**
     * 通过被代理类Bean实例和handler的名字创建代理类
     * @param bean 被代理类Bean实例
     * @param handlerName handler的名字
     * @return 代理类
     */
    private Object createProxy(Object bean, String handlerName) {
        //获取容器
        ConfigurableApplicationContext context = (ConfigurableApplicationContext) ApplicationContextUtils.getRequiredApplicationContext();
        //找到容器中已经注册的名字为handlerName的Bean
        BeanDefinition definition = context.findBeanDefinition(handlerName);
        if (definition == null) {
            throw new AopConfigException("No such handler: " + handlerName);
        }

        //获取handler实例
        Object handler = definition.getInstance();
        if (handler == null) {
            context.createBeanAsEarlySingleton(definition);
            handler = definition.getInstance();
        }
        if (handler instanceof InvocationHandler) {
            //创建代理类
            return proxyResolver.createProxy(bean,(InvocationHandler) handler);
        } else {
            throw new AopConfigException("No matched type handler is InvocationHandler: " + handlerName);
        }
    }

    @Override
    public Object postProcessOnSetProperty(Object bean, String beanName) {
        Object origin  = originBeans.get(beanName);
        return origin == null ? bean : origin;
    }
}
```

使用：

本框架提供的包括：

- Around注解；
- AroundProxyBeanPostProcessor实现AOP。

而客户端代码需要提供的包括：

- 带@Around注解的原始Bean，用于被代理
- 实现InvocationHandler的Bean，名字与@Around注解value保持一致，用于实现代理逻辑

我们完成了Around拦截，而Before拦截和After拦截仅仅是Around的子集，我们可以定义两个新的abstract类，它们实现了InvocationHandler，并有自己的abstract方法`before()` `after()`，如果某个handler实现的是这两个类而不是InvocationHandler，就说明其为Before/After拦截

```java
public abstract class BeforeInvocationHandlerAdapter implements InvocationHandler {

    public abstract void before(Object proxy, Method method, Object[] args) throws Throwable;

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        //先执行before操作
        before(proxy, method, args);
        //再执行原始内容
        return method.invoke(proxy, args);
    }
}

public abstract class AfterInvocationHandlerAdapter implements InvocationHandler {

    //after操作允许对原始方法返回值进行修改
    public abstract Object after(Object proxy, Object ret, Method method, Object[] args) throws Throwable;

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        Object ret = method.invoke(proxy, args);
        return after(proxy, ret, method, args);
    }
}
```

### 扩展@Around注解

目前我们只能靠@Around启动AOP，而像是Spring等提供的@Transactional等也可以启动AOP，如果我们需要其他的注解也可以启动AOP应该怎么做？

进行一个很小的改动即可，我们把AroundProxyBeanPostProcessor变成一个泛型类AnnotationProxyBeanPostProcessor\<A extends Annotation>，其中`Around around = bean.getClass().getAnnotation(Around.class);`用泛型替代。注意泛型不能直接用A.class，实际中其被继承，在子类需要获取带泛型参数的父类，再获取泛型参数的类型

```java
public abstract class AnnotationProxyBeanPostProcessor<A extends Annotation> implements BeanPostProcessor {

    ...

    private final Class<A> annotationType;

    public AnnotationProxyBeanPostProcessor() {
        this.annotationType = getParameterType();
    }

    @Override
    public Object postProcessBeforeInitialization(Object bean, String beanName) {
        //获取注解
        A around = bean.getClass().getAnnotation(annotationType);
        ...
    }

    ...

    /**
     * 获取当前类父类的泛型参数
     * @return 泛型参数
     */
    private Class<A> getParameterType() {
        //获取当前类含有泛型信息的父类，因为当前类是抽象类，调用这个方法的一定是这个类的子类
        Type type = this.getClass().getGenericSuperclass();
        if (!(type instanceof ParameterizedType)) {
            throw new IllegalArgumentException("Class " + this.getClass().getName() + " 没有任何泛型参数");
        }
        Type[] arguments = ((ParameterizedType) type).getActualTypeArguments();
        if (arguments.length != 1) {
            throw new IllegalArgumentException("Class " + this.getClass().getName() + "有超过一个泛型参数");
        }
        Type argument = arguments[0];
        if (!(argument instanceof Class<?>)) {
            throw new IllegalArgumentException("Class" + this.getClass().getName() + "的泛型参数不是Class<?>类型")
        }
        return (Class<A>) argument;
    }
}
```

然后原本的`AroundProxyBeanPostProcessor`只需要继承泛型为`Around`的这个类即可。如果我们想让其它的注解比如`Transactional`启动AOP，也只要新建一个类继承泛型为`Transactional`的这个类
