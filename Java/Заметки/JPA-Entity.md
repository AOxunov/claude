---
tags: [java, spring, jpa, аннотации, entity]
---

# JPA Entity — класс-таблица

Связано с: [[Spring-Data-JPA-Repository]], [[Spring-REST-Controller]], [[00-План]]

**JPA (Java Persistence API)** — стандарт для работы с БД через объекты Java.
**Hibernate** — самая популярная реализация JPA (Spring Boot использует его по умолчанию).

## Идея

Вместо того чтобы писать SQL вручную, ты описываешь таблицу как Java-класс.
JPA сам превращает объекты в SQL и обратно.

```
Java-класс Employee  ←→  таблица employees в PostgreSQL
поле fullName        ←→  колонка full_name
объект employee      ←→  строка в таблице
```

## Основные аннотации

| Аннотация | Что делает |
|---|---|
| `@Entity` | Говорит JPA: этот класс — таблица |
| `@Table(name = "...")` | Имя таблицы (если отличается от класса) |
| `@Id` | Первичный ключ (PRIMARY KEY) |
| `@Column(name = "...")` | Имя колонки (если отличается от поля) |
| `@JdbcTypeCode(SqlTypes.JSON)` | Хранить поле как JSON/JSONB в PostgreSQL |

## Пример из проекта

```java
@Entity
@Table(name = "employees")
public class Employee {

    @Id
    private UUID id;  // UUID — уникальный идентификатор (не автоинкремент)

    @Column(name = "full_name")
    private String fullName;  // поле Java ← → колонка full_name в БД

    private int state;  // имя совпадает с колонкой → @Column не нужна

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "attributes", columnDefinition = "jsonb")
    private Map<String, Object> attributes;  // JSON-поле в PostgreSQL
}
```

## Геттеры и сеттеры (инкапсуляция)

Поля — `private`. Доступ только через методы:

```java
public String getFullName() { return fullName; }
public void setFullName(String fullName) { this.fullName = fullName; }
```

JPA и Spring требуют геттеры/сеттеры, чтобы читать и записывать значения.

## Обязательный пустой конструктор

```java
public Employee() {}
```

JPA создаёт объекты через reflection — ему нужен конструктор без аргументов.

## Типы данных

| Java-тип | Что хранит | SQL-тип |
|---|---|---|
| `String` | Строка | VARCHAR / TEXT |
| `int` | Целое число | INTEGER |
| `long` | Большое целое | BIGINT |
| `double` | Дробное число | DOUBLE PRECISION |
| `UUID` | Уникальный ID | UUID |
| `LocalDateTime` | Дата + время | TIMESTAMP |
| `Map<String, Object>` | Произвольный JSON | JSONB |

## Частые ошибки

- Забыть пустой конструктор → Hibernate выбросит исключение при старте
- Имя метода не совпадает с именем поля (пример: `setUpdated_by` вместо `setUpdatedBy`) → Jackson не сможет сериализовать