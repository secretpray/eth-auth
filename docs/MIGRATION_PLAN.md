# План миграции с gem "siwe" на gem "eth"

## Дата создания: 2025-12-30

## Цель
Перевести проект с gem "siwe" на gem "eth" с сохранением всего функционала многоуровневой защиты, потока аутентификации и дизайна.

## Текущее состояние

### Используемые технологии
- **gem "siwe"** - реализация EIP-4361 (Sign-In With Ethereum)
- **Формат сообщения**: Структурированный SIWE message с полями (domain, uri, chainId, nonce, issuedAt, expirationTime)
- **Верификация**: `Siwe::Message.verify()` - комплексная проверка всех полей + подписи

### Многоуровневая система безопасности
1. **Layer 1**: IP-based rate limiting (10 req/min для аутентификации)
2. **Layer 2**: Nonce endpoint rate limiting (30 req/min per IP:address)
3. **Layer 3**: Nonce TTL с auto-expiration (10 минут в cache)
4. **Layer 4**: One-time nonce usage (отметка в cache)
5. **Layer 5**: Nonce invalidation после успешной аутентификации

### Ключевые файлы
- `Gemfile` - зависимости
- `app/services/siwe_authentication_service.rb` - сервис верификации SIWE
- `app/controllers/sessions_controller.rb` - контроллер сессий с rate limiting
- `app/controllers/api/v1/users_controller.rb` - генерация nonce с rate limiting
- `app/javascript/controllers/wallet_login_controller.js` - фронтенд логика
- `app/models/user.rb` - модель пользователя
- `docs/AUTHENTICATION.md` - документация

## Целевое состояние

### Новые технологии
- **gem "eth"** - низкоуровневая библиотека для работы с Ethereum
- **Формат сообщения**: Упрощенный формат "AppName,{timestamp},{nonce}"
- **Верификация**: `Eth::Signature.personal_recover()` + сравнение адресов

### Методы gem "eth"
```ruby
# Валидация адреса
Eth::Address.new(address).valid?

# Восстановление публичного ключа из подписи
signature_pubkey = Eth::Signature.personal_recover(message, signature)

# Конвертация публичного ключа в адрес
recovered_address = Eth::Util.public_key_to_address(signature_pubkey).to_s.downcase
```

### Сохранение многоуровневой защиты
Все 5 уровней безопасности остаются без изменений:
- Rate limiting (IP + endpoint)
- Cache-based nonce management
- TTL и one-time usage
- Nonce invalidation

### Поток аутентификации (неизменный)
1. Пользователь открывает главную страницу (одна точка входа)
2. Клик "Connect Wallet"
3. Запрос nonce: `GET /api/v1/users/:eth_address`
4. Генерация упрощенного сообщения
5. Подпись сообщения в MetaMask
6. Отправка на сервер: `POST /session`
7. Верификация подписи
8. Создание/вход пользователя
9. Редирект на дашборд

## Этапы миграции

### Этап 1: Подготовка зависимостей
**Файлы**: `Gemfile`, `Gemfile.lock`

**Действия**:
1. Заменить `gem "siwe"` на `gem "eth"`
2. Выполнить `bundle install`
3. Проверить совместимость с Ruby 3.4.1 и Rails 8.1.1

**Ожидаемый результат**: Gem "eth" установлен и готов к использованию

---

### Этап 2: Создание нового сервиса аутентификации
**Файлы**: `app/services/eth_authentication_service.rb` (новый)

**Действия**:
1. Создать новый сервис `EthAuthenticationService`
2. Скопировать структуру из `SiweAuthenticationService`:
   - Инициализация с параметрами (eth_address, message, signature, request)
   - Метод `authenticate` с полным флоу
   - Приватные методы безопасности
3. Реализовать новый метод `verify_signature`:
   ```ruby
   def verify_signature
     # Парсинг сообщения "AppName,{timestamp},{nonce}"
     parts = @message.split(',')
     return false unless parts.length == 3

     timestamp = parts[1].to_i
     nonce_from_message = parts[2]

     # Проверка nonce
     unless nonce_from_message == @cached_nonce
       @errors << "Nonce mismatch"
       return false
     end

     # Проверка timestamp (не старше 5 минут)
     if Time.current.to_i - timestamp > 300
       @errors << "Signature expired"
       return false
     end

     # Восстановление адреса из подписи
     signature_pubkey = Eth::Signature.personal_recover(@message, @signature)
     recovered_address = Eth::Util.public_key_to_address(signature_pubkey).to_s.downcase

     # Сравнение адресов
     unless recovered_address == @eth_address
       @errors << "Invalid signature"
       return false
     end

     true
   rescue => e
     @errors << "Signature verification failed"
     false
   end
   ```
4. Сохранить все методы безопасности без изменений:
   - `perform_security_checks`
   - `nonce_already_used?`
   - `mark_nonce_as_used`
   - `invalidate_nonce`
   - `create_or_find_user`

**Ожидаемый результат**: Новый сервис с той же структурой безопасности, но с упрощенной верификацией через gem "eth"

---

### Этап 3: Обновление контроллера сессий
**Файлы**: `app/controllers/sessions_controller.rb`

**Действия**:
1. Заменить `SiweAuthenticationService` на `EthAuthenticationService` в методе `auth_service`
2. Оставить все остальное без изменений:
   - Rate limiting
   - Валидация адреса
   - Обработка ошибок
   - Turbo Streams response

**Изменения**:
```ruby
def auth_service
  @auth_service ||= EthAuthenticationService.new(
    eth_address:,
    message: siwe_message_param,  # Переименовать в message_param
    signature: signature_param,
    request:
  )
end
```

**Ожидаемый результат**: Контроллер использует новый сервис, rate limiting работает

---

### Этап 4: Обновление JavaScript фронтенда
**Файлы**: `app/javascript/controllers/wallet_login_controller.js`

**Действия**:
1. Заменить генерацию SIWE message на упрощенный формат
2. Сохранить всю остальную логику:
   - Подключение к кошельку
   - Запрос nonce
   - Подпись сообщения
   - Отправка формы

**Изменения**:
```javascript
// Старый SIWE формат (удалить):
const message = `${domain} wants you to sign in with your Ethereum account:
${account}

Sign in to the app.

URI: ${uri}
Version: 1
Chain ID: 1
Nonce: ${data.eth_nonce}
Issued At: ${issuedAt}
Expiration Time: ${expirationTime}`

// Новый упрощенный формат:
const timestamp = Math.floor(Date.now() / 1000)
const message = `Blockchain Auth,${timestamp},${data.eth_nonce}`
```

**Ожидаемый результат**: Фронтенд генерирует упрощенное сообщение, все остальное работает

---

### Этап 5: Удаление старого сервиса
**Файлы**: `app/services/siwe_authentication_service.rb`

**Действия**:
1. Удалить файл `siwe_authentication_service.rb`
2. Убедиться, что никакие другие файлы не ссылаются на него

**Ожидаемый результат**: Старый сервис удален, проект использует только новый

---

### Этап 6: Обновление документации
**Файлы**:
- `docs/AUTHENTICATION.md`
- `README.md`
- `Gemfile` (комментарии)

**Действия**:
1. Обновить `docs/AUTHENTICATION.md`:
   - Заменить упоминания SIWE/EIP-4361 на "Ethereum Signature Authentication"
   - Обновить примеры кода с `Siwe::Message.verify` на `Eth::Signature.personal_recover`
   - Обновить формат сообщения в диаграммах
   - Указать новый формат: "AppName,{timestamp},{nonce}"
   - Сохранить описание всех 5 уровней безопасности
2. Обновить `README.md`:
   - Заменить бейджи EIP-4361/EIP-191
   - Обновить раздел "Technology Stack"
   - Обновить раздел "Web3 & Ethereum Protocols"
3. Обновить комментарий в `Gemfile`:
   ```ruby
   gem "eth" # Ethereum signature verification library
   ```

**Ожидаемый результат**: Документация отражает новую реализацию

---

### Этап 7: Тестирование
**Действия**:
1. Запустить приложение локально
2. Проверить полный флоу аутентификации:
   - Открыть главную страницу
   - Подключить кошелек
   - Подписать сообщение
   - Проверить успешный вход
   - Проверить создание пользователя
3. Проверить многоуровневую защиту:
   - Rate limiting (попытаться превысить лимиты)
   - Nonce TTL (подождать 10 минут)
   - One-time usage (попытаться переиспользовать подпись)
   - Replay attack (повторная отправка старой подписи)
4. Проверить обработку ошибок:
   - Неверная подпись
   - Истекший nonce
   - Использованный nonce
   - Неверный адрес
5. Проверить UI/UX:
   - Turbo Streams работают
   - Flash сообщения отображаются
   - Редиректы работают
   - Дизайн не изменился

**Ожидаемый результат**: Все работает идентично старой версии

---

## Риски и митигация

### Риск 1: Различия в восстановлении подписи
**Описание**: gem "eth" может восстанавливать адрес по-другому, чем gem "siwe"

**Митигация**:
- Тщательно протестировать с разными кошельками (MetaMask, WalletConnect)
- Использовать `personal_recover` (префикс "\x19Ethereum Signed Message:\n")
- Нормализовать адреса к lowercase

### Риск 2: Формат сообщения
**Описание**: Упрощенный формат может быть менее читаемым для пользователя

**Митигация**:
- Можно сделать более понятный формат: "Sign in to Blockchain Auth at {timestamp} with nonce {nonce}"
- Пользователь видит сообщение в MetaMask перед подписью

### Риск 3: Обратная совместимость
**Описание**: Существующие пользователи не смогут войти

**Митигация**:
- Не требуется: пользователи просто подпишут новое сообщение
- Nonce хранится в cache, а не в БД пользователя

### Риск 4: Безопасность
**Описание**: Потеря какого-то уровня защиты при миграции

**Митигация**:
- Весь код безопасности (rate limiting, nonce management) остается без изменений
- Меняется только метод верификации подписи

## Откат (Rollback Plan)

Если миграция не удалась:
1. Восстановить gem "siwe" в Gemfile
2. Выполнить `bundle install`
3. Восстановить `siwe_authentication_service.rb` из git
4. Восстановить старый JavaScript контроллер
5. Обновить `sessions_controller.rb` обратно
6. Перезапустить сервер

**Важно**: Сделать git commit перед началом миграции!

## Чек-лист выполнения

- [ ] **Этап 1**: Обновлен Gemfile, установлен gem "eth"
- [ ] **Этап 2**: Создан EthAuthenticationService
- [ ] **Этап 3**: Обновлен SessionsController
- [ ] **Этап 4**: Обновлен wallet_login_controller.js
- [ ] **Этап 5**: Удален SiweAuthenticationService
- [ ] **Этап 6**: Обновлена документация
- [ ] **Этап 7**: Проведено полное тестирование
- [ ] **Финал**: Создан git commit с изменениями

## Ожидаемые результаты

### Технические
- Успешная аутентификация через Ethereum кошельки
- Все 5 уровней безопасности работают
- Rate limiting функционирует
- Nonce management через cache
- Создание пользователей только после верификации

### Функциональные
- Одна точка входа (главная страница)
- Неизменный UI/UX
- Turbo Streams работают
- Flash сообщения отображаются
- Дизайн сохранен

### Производительность
- Верификация подписи должна быть быстрее (gem "eth" более низкоуровневый)
- Меньше зависимостей
- Меньше парсинга (упрощенный формат сообщения)

## Дополнительные улучшения (опционально)

После успешной миграции можно рассмотреть:

1. **Улучшение формата сообщения**:
   ```
   "Sign in to Blockchain Auth
   Timestamp: {iso8601_timestamp}
   Nonce: {nonce}"
   ```

2. **Добавление chain ID проверки**:
   - Хранить chain ID в сообщении
   - Проверять, что пользователь подписал с нужной сети

3. **Расширенная валидация**:
   - Проверка формата signature (length, prefix)
   - Дополнительные проверки публичного ключа

## Вопросы для обсуждения

1. Какой формат сообщения использовать? (простой "App,timestamp,nonce" или более читаемый?)
2. Нужно ли сохранять логи старых SIWE аутентификаций?
3. Нужно ли уведомлять пользователей о смене формата подписи?

## Заключение

Миграция с gem "siwe" на gem "eth" является относительно простой, так как:
- Вся инфраструктура безопасности (cache, rate limiting) остается без изменений
- Меняется только метод верификации подписи
- Не требуется миграция базы данных
- Не нужна обратная совместимость (пользователи просто подпишут новое сообщение)

Основное преимущество: меньше зависимостей, больше контроля над процессом верификации.

---

**Автор**: Claude Sonnet 4.5
**Дата**: 2025-12-30
**Версия**: 1.0
