---
tags: [java, spring, jpa, repository, generics, interface]
---

# Spring Data JPA — Repository

Связано с: [[JPA-Entity]], [[Spring-REST-Controller]], [[00-План]]

## Идея

Spring Data JPA позволяет работать с БД без написания SQL.
Ты описываешь **интерфейс** — Spring сам создаёт реализацию во время запуска приложения.

## Интерфейс vs Класс

```java
// Класс — содержит реализацию
public class MyClass {
    public void doSomething() { /* логика */ }
}

// Интерфейс — только контракт (что можно делать, но не как)
public interface MyInterface {
    void doSomething(); // нет тела метода
}
```

`EmployeeRepository` — это **интерфейс**. Spring Boot видит его и автоматически
создаёт объект с готовой реализацией (прокси-класс).

## Пример из проекта

```java
@Repository
public interface EmployeeRepository extends JpaRepository<Employee, UUID> {
}
```

### `extends JpaRepository<Employee, UUID>`

`JpaRepository` — это интерфейс Spring с готовыми методами.
`<Employee, UUID>` — **generics** (обобщения):
- `Employee` — с какой сущностью работаем
- `UUID` — тип первичного ключа (`@Id`)

### Готовые методы из JpaRepository (бесплатно)

| Метод | Что делает |
|---|---|
| `findAll()` | Получить все записи → `SELECT * FROM employees` |
| `findById(id)` | Найти по ID → `SELECT * WHERE id = ?` |
| `save(entity)` | Создать или обновить → `INSERT` или `UPDATE` |
| `deleteById(id)` | Удалить по ID → `DELETE WHERE id = ?` |
| `count()` | Количество записей → `SELECT COUNT(*)` |
| `existsById(id)` | Существует ли запись → `SELECT EXISTS(...)` |

## Generics — зачем нужны

Без generics пришлось бы писать так:
```java
Object result = repository.findById(id); // непонятно какой тип
Employee e = (Employee) result;           // небезопасное приведение типов
```

С generics:
```java
Optional<Employee> result = repository.findById(id); // компилятор знает тип
```

Generics = подсказка компилятору о типах → меньше ошибок в рантайме.

## @Repository

Аннотация говорит Spring: «создай объект (bean) этого типа и управляй им».
Spring сам создаёт и хранит этот объект — ты только объявляешь интерфейс.