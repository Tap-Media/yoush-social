# API List

This file lists network APIs/endpoints called by the app code.

## 1) Mastodon Server APIs
Base URL: `https://{server}` where `server` defaults to `mastodon.honviet247.com`.
Source: `lib/core/network/mastodon_service.dart`, `lib/core/constants/api_constants.dart`.

| Method | Endpoint |
|---|---|
| GET | `/api/v1/accounts/verify_credentials` |
| POST | `/oauth/token` |
| GET | `/api/v2/instance` |
| GET | `/api/v1/instance` (fallback) |
| GET | `/api/v1/timelines/public` |
| GET | `/api/v1/timelines/home` |
| GET | `/api/v1/timelines/tag/{tag}` |
| GET | `/api/v1/conversations` |
| GET | `/api/v1/accounts/{accountId}/statuses` |
| GET | `/api/v1/bookmarks` |
| POST | `/api/v1/statuses/{statusId}/favourite` |
| POST | `/api/v1/statuses/{statusId}/unfavourite` |
| POST | `/api/v1/statuses/{statusId}/reblog` |
| POST | `/api/v1/statuses/{statusId}/unreblog` |
| POST | `/api/v1/statuses/{statusId}/bookmark` |
| POST | `/api/v1/statuses/{statusId}/unbookmark` |
| POST | `/api/v1/statuses/{statusId}/pin` |
| POST | `/api/v1/statuses/{statusId}/unpin` |
| POST | `/api/v1/statuses/{statusId}/mute` |
| POST | `/api/v1/statuses/{statusId}/unmute` |
| GET | `/api/v1/statuses/{statusId}` |
| DELETE | `/api/v1/statuses/{statusId}` |
| PUT | `/api/v1/statuses/{statusId}` |
| POST | `/api/v1/media` |
| GET | `/api/v1/media/{mediaId}` |
| GET | `/api/v1/statuses/{statusId}/context` |
| POST | `/api/v1/statuses` |
| GET | `/api/v2/search` |
| GET | `/api/v1/trends/tags` |
| GET | `/api/v1/trends/links` |
| GET | `/api/v1/trends/statuses` |
| GET | `/api/v1/notifications` |
| POST | `/api/v1/notifications/clear` |
| POST | `/api/v1/notifications/dismiss` |
| GET | `/api/v1/accounts/relationships` |
| GET | `/api/v1/accounts/{accountId}` |
| POST | `/api/v1/accounts/{accountId}/follow` |
| POST | `/api/v1/accounts/{accountId}/unfollow` |
| POST | `/api/v1/reports` |
| POST | `/api/v1/accounts/{accountId}/block` |
| POST | `/api/v1/accounts/{accountId}/unblock` |
| POST | `/api/v1/accounts/{accountId}/mute` |
| POST | `/api/v1/accounts/{accountId}/unmute` |
| GET | `/api/v1/preferences` |
| PATCH | `/api/v1/accounts/update_credentials` |
| GET | `/api/v1/accounts/{id}/following` |

### Mastodon Streaming
Source: `lib/core/network/mastodon_service.dart`.

| Protocol | Endpoint |
|---|---|
| WSS | `wss://mastodon.honviet247.com/api/v1/streaming?stream={stream}[&access_token=...]` |
| GET | `https://mastodon.honviet247.com/api/v1/streaming/health` |

## 2) Internal Auth APIs
Base URL: `https://internal-api.youshsocial.com`
Source: `lib/feature/auth/data/datasources/auth_remote_datasource.dart`, `lib/feature/auth/presentation/providers/auth_provider.dart`.

| Method | Endpoint |
|---|---|
| POST | `/auth/sign_in` |
| POST | `/auth/sign_up` |
| POST | `/auth/delete` |

## 3) Tap News APIs
Base URL: `https://api.iamtapnews.com`
Source: `lib/core/network/tap_news_service.dart`.

| Method | Endpoint |
|---|---|
| GET | `/api/news` |
| GET | `/api/admin-console/menus` |
| GET | `/api/admin-console/news/{slug}` |
