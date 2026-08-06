---
tags: [java, spring, rest, controller, di, ioc]
---

# Spring REST Controller

Связано с: [[JPA-Entity]], [[Spring-Data-JPA-Repository]], [[Spring-Core-DI]], [[00-План]]

## Что делает контроллер

Принимает HTTP-запросы и возвращает ответы (JSON).

```
Клиент (браузер/Postman)
    │  HTTP GET /api/v1/employees
    ▼
EmployeeController.findAll()
    │  repository.findAll()
    ▼
EmployeeRepository → PostgreSQL
    │  List<Employee>
    ▼
EmployeeController → JSON → Клиент
```

## Пример из проекта

```java
@RestController                       // = @Controller + @ResponseBody
@RequestMapping("/api/v1/employees")  // базовый URL для всех методов

public class EmployeeController {

    private final EmployeeRepository repository;

    // Dependency Injection через конструктор
    public EmployeeController(EmployeeRepository repository) {
        this.repository = repository;
    }

    @GetMapping               // GET /api/v1/employees
    public List<Employee> findAll() {
        return repository.findAll();  // Spring сам превращает List в JSON
    }

    @PostMapping              // POST /api/v1/employees
    public Employee save(@RequestBody Employee employee) {
        return repository.save(employee);
    }
}
```

## Аннотации HTTP-методов

| Аннотация | HTTP-метод | Типичное действие |
|---|---|---|
| `@GetMapping` | GET | Получить данные |
| `@PostMapping` | POST | Создать новый объект |
| `@PutMapping` | PUT | Обновить целиком |
| `@PatchMapping` | PATCH | Обновить частично |
| `@DeleteMapping` | DELETE | Удалить |

## @RequestBody и @PathVariable

```java
// @RequestBody — читает JSON из тела запроса и превращает в объект
@PostMapping
public Employee save(@RequestBody Employee employee) { ... }

// @PathVariable — читает часть URL
@GetMapping("/{id}")
public Employee findById(@PathVariable UUID id) { ... }
```

## Dependency Injection (DI) — внедрение зависимостей

**Проблема без DI:**
```java
// Плохо — класс сам создаёт зависимость
public class EmployeeController {
    private EmployeeRepository repository = new EmployeeRepository(); // нельзя так с интерфейсом!
}
```

**DI через конструктор (рекомендуется):**
```java
public class EmployeeController {
    private final EmployeeRepository repository;

    public EmployeeController(EmployeeRepository repository) {
        this.repository = repository; // Spring сам передаёт объект
    }
}
```

Spring держит все объекты (beans) в контейнере IoC.
Когда нужен `EmployeeController`, Spring видит: «ему нужен `EmployeeRepository`» →
находит готовый объект в контейнере → передаёт в конструктор.

**`private final`** — поле нельзя переназначить после конструктора. Правильная практика для DI.

## @RestController vs @Controller

- `@Controller` — возвращает имя HTML-шаблона (для MVC с Thymeleaf и т.п.)
- `@RestController` — возвращает данные (JSON/XML), без шаблонов. = `@Controller` + `@ResponseBody`