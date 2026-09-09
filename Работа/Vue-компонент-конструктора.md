---
tags: [работа, realsoft, vue, платон]
---

# Как писать компонент в конструкторе realsoft (Platon)

Справочник для себя и для нового чата: каркас, ограничения, обязательные приёмы
и грабли, на которые уже наступали. См. [[Vue-сниппеты]], [[Туризм]], [[00-Обо-мне]].

Всё проверено на компоненте `ProcurementDocument` (двуязычная закупочная
документация с живым предпросмотром), сентябрь 2025.

---

## 1. Каркас: что вообще есть

Компонент в конструкторе — это форма из пяти полей:

| Поле | Что кладём |
|---|---|
| `name` | PascalCase. Им же вызывается тег: `<ProcurementDocument />` |
| `note` | комментарий для человека, в рантайм не попадает |
| `is_global` | вкл — компонент виден на всех страницах; выкл — только там, где подключён |
| `content` | шаблон Vue |
| `js` | **голый объект опций**, без `export default` |
| `css` | обычный CSS, **не scoped** |

---

## 2. Жёсткие ограничения

**Vue 2, не Vue 3.** Отсюда `beforeDestroy` (не `beforeUnmount`), классы перехода
`-enter` / `-enter-active` / `-leave-to` (не `-enter-from`), нет фрагментов.

**`js` — это `{ ... }`, а не `export default { ... }`.** Платформа сама оборачивает
объект. Значит **`import` недоступен**: любая внешняя зависимость берётся только
из глобалей — `window`, `navigator`, `localStorage`, `document`. Константы
объявляются внутри `data()` перед `return`.

**Один корневой элемент в `content`.** Vue 2 не умеет несколько корней.

**CSS глобальный.** Все правила потекут на соседние страницы, если не изолировать.
Обязательный приём — уникальный префикс класса и всё под корневым классом:

```css
.pd-root .pd-input { ... }   /* pd- = ProcurementDocument */
```

---

## 3. Структура `js`

Порядок опций, которого держимся:

```js
{
  props: { ... },

  data() {
    // здесь же объявляем все константы: FIELDS, GROUPS, тексты, шаблоны
    const FIELDS = [ ... ];

    return {
      FIELDS: Object.freeze(FIELDS),   // см. п.4
      values: values,                  // все ключи объявлены заранее, см. п.4
      loading: false
    };
  },

  computed: { ... },
  watch:    { ... },
  mounted() { ... },
  beforeDestroy() { ... },   // парная очистка, см. п.4
  methods:  { ... }
}
```

---

## 4. Обязательные приёмы

### 4.1. Все реактивные ключи объявляем заранее

Vue 2 не отслеживает свойства, добавленные в объект после создания.

```js
const values = {};
const errors = {};
FIELDS.forEach(function (f) {
  values[f.key] = '';
  errors[f.key] = '';
});
return { values: values, errors: errors };
```

### 4.2. `Object.freeze` для больших константных данных

Vue 2 не оборачивает замороженные объекты в реактивность. Массив из 180 блоков
документа не попадает в систему наблюдения — экономит и память, и время старта.

```js
return { DOC: Object.freeze(DOC) };
```

### 4.3. Присваивание по индексу массива НЕ реактивно

Классические грабли Vue 2. `this.list[i] = 'x'` и `v-model="list[i]"` не работают.

```js
// ПЛОХО
members: ['', '', '', '']          // v-model="members[i]" молча не обновит вид

// ХОРОШО — массив объектов, меняем свойство
members: [{ v: '', e: '' }, ...]   // v-model="m.v" работает
```

Мутирующие методы (`push`, `splice`, `sort`) Vue патчит — они реактивны.

### 4.4. Каждой подписке — парная отписка

Компоненты живут внутри SPA-роутера, страницы перемонтируются. Невычищенный
таймер потом стреляет на чужой странице.

```js
mounted() {
  document.addEventListener('visibilitychange', this.onVisibilityChange);
  window.addEventListener('pagehide', this.onPageHide);
},

beforeDestroy() {
  document.removeEventListener('visibilitychange', this.onVisibilityChange);
  window.removeEventListener('pagehide', this.onPageHide);
  if (this.timer) clearTimeout(this.timer);
}
```

Обратите внимание: `visibilitychange` вешается на `document`, `pagehide` — на
`window`. При копировании легко перепутать и отписаться не оттуда.

### 4.5. Не-реактивные служебные свойства — мимо `data`

Токен отмены анимации, счётчик и прочее, что не должно вызывать перерисовку:

```js
this._scrollToken = (this._scrollToken || 0) + 1;   // намеренно вне data()
```

---

## 5. Работа с API

```js
this.$api.get(`v1/procurement?id=${this.id}`).then(res => {
  const data = res.data.data;
}).catch(e => { });

this.$api.post(`v1/procurement`, body).then(res => { }).catch(e => { });
```

Состояния держим явно: `loading`, `saving`, `notice`. Кнопку блокируем на время
запроса, guard от двойного клика в начале метода:

```js
submit() {
  if (this.saving || this.loading) return;
  ...
}
```

Если проп `id` может прийти после монтирования — нужен `watch`, одного `mounted`
мало:

```js
watch: { id() { this.load(); } },
mounted() { this.load(); }
```

---

## 6. Локализация

В проекте живут два механизма — выбирать надо один осознанно:

```html
{{ $l('detail.about', 'About') }}          <!-- платформенный хелпер, предпочтительно -->
{{ texts.subtitle }}                        <!-- свой словарь в computed -->
```

Свой словарь — обходной путь, когда ключей в справочнике нет:

```js
locale: localStorage.getItem('platon_locale') || 'uz'
// texts() { const t = { uz: {...}, ru: {...} }; return t[this.locale] || t.uz; }
```

Значения выбора (месяц, квартал) храним **номером**, а подпись локализуем при
выводе. Иначе при смене языка в базе окажется «Сентябрь» в узбекском документе.

---

## 7. Грабли окружения — проверено, ломается молча

### 7.1. `scrollTo({ behavior: 'smooth' })` может не работать вообще

В части окружений и при `prefers-reduced-motion` вызов молча ничего не делает.
Пишем свою анимацию, с мгновенным переходом там, где анимировать нельзя,
и со страховкой на случай, если `requestAnimationFrame` не тикает:

```js
scrollViewTo(view, target) {
  const max = view.scrollHeight - view.clientHeight;
  const top = Math.max(0, Math.min(target, max));
  const start = view.scrollTop;
  const dist = top - start;

  this._scrollToken = (this._scrollToken || 0) + 1;
  const token = this._scrollToken;
  const self = this;

  const reduce = window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // на скрытой вкладке requestAnimationFrame не вызывается
  if (reduce || document.hidden || Math.abs(dist) < 4 || !window.requestAnimationFrame) {
    view.scrollTop = top;
    return;
  }

  const t0 = Date.now();
  const dur = 420;

  const step = function () {
    if (token !== self._scrollToken) return;
    const p = Math.min(1, (Date.now() - t0) / dur);
    const e = p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
    view.scrollTop = start + dist * e;
    if (p < 1) window.requestAnimationFrame(step);
  };

  window.requestAnimationFrame(step);

  // если rAF так и не вызвался — доводим прокрутку сами
  window.setTimeout(function () {
    if (token !== self._scrollToken) return;
    if (Math.abs(view.scrollTop - top) > 2) view.scrollTop = top;
  }, dur + 120);
}
```

### 7.2. `offsetTop` врёт внутри таблиц

По спецификации `offsetParent` — это ближайший позиционированный предок **или
ближайший `td` / `th` / `table`**, что встретится раньше. Для элемента внутри
ячейки побеждает ячейка, и `offsetTop` вернёт единицы пикселей вместо реального
положения. Прокрутка уедет в начало страницы.

```js
// ПЛОХО — сломается внутри любой таблицы
const top = el.offsetTop - view.clientHeight / 3;

// ХОРОШО — не зависит от предков
const top = view.scrollTop +
  (el.getBoundingClientRect().top - view.getBoundingClientRect().top) -
  view.clientHeight / 3;
```

### 7.3. Форматирование числа по `input` двигает каретку

Перестановка разрядов на каждое нажатие кидает курсор в конец при правке
середины числа. Чистим мусор по `input`, форматируем по `blur`.

```js
onInput(f) {  // только убрать лишние символы
  this.values[f.key] = String(this.values[f.key]).replace(/[^\d ]/g, '');
},
onBlur(f) {   // здесь уже расставляем разряды
  this.values[f.key] = this.groupDigits(String(this.values[f.key]).replace(/\D/g, ''));
}
```

### 7.4. `keyup` вместо `input` ломает вставку мышью

Если вешаем обработчик руками — только `input`. На `keyup` не сработают вставка
из контекстного меню и автозаполнение браузера. С `v-model` проблемы нет.

---

## 8. Приёмы вёрстки, которые пригодились

**Живой предпросмотр вместо `v-html`.** Текст хранится как данные с токенами
`{{ключ}}`, разбирается на сегменты и рендерится через `v-for`. Даёт
реактивность из коробки и закрывает XSS — вставка идёт текстом, не разметкой.

**Пустое поле показывает свою подпись.** Не прочерк, а название поля — документ
читается связным текстом с первой секунды.

**Подсветка + автоскролл.** Фокус в поле формы подсвечивает соответствующее
место в предпросмотре и прокручивает к нему. Ищем через `data`-атрибут:

```js
view.querySelector('[data-f="' + key + '"][data-side="' + side + '"]')
```

**Непрерывная пунктирная граница.** Если отступы между строками задавать
`margin`, граница будет рваться. Задаём `padding` внутри ячеек — строки касаются,
линия идёт сплошняком.

---

## 9. Минимальный скелет

**content**

```html
<div class="xx-root">
  <div class="xx-field" v-for="f in FIELDS" :key="f.key">
    <label class="xx-label" :for="'xx-' + f.key">{{ f.label }}</label>
    <input class="xx-input"
           :id="'xx-' + f.key"
           :class="{ 'is-invalid': errors[f.key] }"
           :disabled="loading"
           v-model="values[f.key]"
           @input="clearError(f.key)" />
    <div class="xx-error" v-if="errors[f.key]">{{ errors[f.key] }}</div>
  </div>

  <button type="button" class="xx-btn" :disabled="saving" @click="submit">
    {{ saving ? 'Yuborilmoqda...' : 'Yaratish' }}
  </button>
</div>
```

**js**

```js
{
  props: {
    id: { type: [String, Number], default: null }
  },

  data() {
    const FIELDS = [
      { key: 'name',  label: 'Nomi',  required: true },
      { key: 'price', label: 'Narxi', required: true }
    ];

    const values = {};
    const errors = {};
    FIELDS.forEach(function (f) { values[f.key] = ''; errors[f.key] = ''; });

    return {
      FIELDS: Object.freeze(FIELDS),
      values: values,
      errors: errors,
      loading: false,
      saving: false
    };
  },

  watch: { id() { this.load(); } },

  mounted() { this.load(); },

  methods: {
    clearError(key) {
      if (this.errors[key]) this.errors[key] = '';
    },

    validate() {
      const self = this;
      let ok = true;
      this.FIELDS.forEach(function (f) {
        const empty = !String(self.values[f.key] || '').trim();
        self.errors[f.key] = (f.required && empty) ? 'Maydonni to‘ldiring' : '';
        if (self.errors[f.key]) ok = false;
      });
      return ok;
    },

    load() {
      if (!this.id) return;
      this.loading = true;
      const self = this;

      this.$api.get(`v1/thing?id=${this.id}`).then(res => {
        const data = res.data.data;
        self.FIELDS.forEach(function (f) {
          self.values[f.key] = data && data[f.key] != null ? String(data[f.key]) : '';
        });
        self.loading = false;
      }).catch(e => {
        self.loading = false;
      });
    },

    submit() {
      if (this.saving || this.loading) return;
      if (!this.validate()) return;

      this.saving = true;
      const body = { name: this.values.name, price: this.values.price };
      if (this.id) body.id = this.id;

      const self = this;
      this.$api.post(`v1/thing`, body).then(res => {
        self.saving = false;
        self.$emit('saved', res && res.data ? res.data : null);
      }).catch(e => {
        self.saving = false;
      });
    }
  }
}
```

**css**

```css
.xx-root { font-family: -apple-system, "Segoe UI", Roboto, Arial, sans-serif; }

.xx-root .xx-field { margin-bottom: 14px; }

.xx-root .xx-label {
  display: block;
  margin-bottom: 5px;
  font-size: 12px;
  color: #4b5563;
}

.xx-root .xx-input {
  display: block;
  width: 100%;
  padding: 9px 11px;
  border: 1px solid #d1d5db;
  border-radius: 8px;
  font-family: inherit;
  font-size: 14px;
  outline: none;
  box-sizing: border-box;
}

.xx-root .xx-input:focus {
  border-color: #2563eb;
  box-shadow: 0 0 0 3px rgba(37, 99, 235, .12);
}

.xx-root .xx-input.is-invalid { border-color: #dc2626; }

.xx-root .xx-error { margin-top: 4px; font-size: 11px; color: #dc2626; }

.xx-root .xx-btn {
  padding: 11px 22px;
  border: none;
  border-radius: 9px;
  background: #2563eb;
  color: #fff;
  font-family: inherit;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
}

.xx-root .xx-btn:disabled { opacity: .55; cursor: default; }
```

---

## 10. Чек-лист перед сдачей

- [ ] один корневой элемент в `content`
- [ ] в `js` нет `import` и нет `export default`
- [ ] все реактивные ключи объявлены в `data()` заранее
- [ ] большие константы обёрнуты в `Object.freeze`
- [ ] нет присваивания по индексу массива (либо массив объектов)
- [ ] каждой подписке и таймеру есть парная очистка в `beforeDestroy`
- [ ] уникальный CSS-префикс, все правила под корневым классом
- [ ] прокрутка считается через `getBoundingClientRect`, не `offsetTop`
- [ ] `behavior: 'smooth'` не единственный способ прокрутить
- [ ] числа форматируются по `blur`, не по `input`
- [ ] guard от двойного клика в `submit`
- [ ] кнопка и поля блокируются на время запроса
- [ ] значения выбора хранятся кодом, подпись локализуется при выводе
- [ ] проверено на узком экране

---

## 11. Как отлаживать без конструктора

Собираем локальный стенд: обычный HTML, Vue 2 с CDN, шаблон в
`<script type="text/x-template">`, заглушка `$api` через `Vue.prototype`.

```html
<script src="https://cdnjs.cloudflare.com/ajax/libs/vue/2.7.16/vue.js"></script>

<div id="app"><my-component :id="docId"></my-component></div>

<script type="text/x-template" id="tpl">
  <!-- сюда содержимое поля content -->
</script>

<script>
  var opts = /* сюда содержимое поля js */;
  opts.template = document.getElementById('tpl').innerHTML;

  Vue.prototype.$api = {
    get:  function (url)       { return Promise.resolve({ data: { data: { /* ... */ } } }); },
    post: function (url, body) { window.__lastPost = body; return Promise.resolve({ data: {} }); }
  };

  Vue.component('my-component', opts);
  window.vm = new Vue({ el: '#app', data: { docId: null } });
</script>
```

Через `window.vm.$children[0]` дальше можно дёргать методы и проверять состояние
прямо из консоли. Отдавать компонент в конструктор имеет смысл только после того,
как стенд отработал без ошибок.
