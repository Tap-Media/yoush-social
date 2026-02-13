# Memories Feature

This feature allows users to rediscover their statuses posted on the same day in previous years.

## Overview

The feature provides an API endpoint that retrieves statuses created by the current user on the current month and day, but from years prior to the current year.

## Integration Flow

1.  **Check Feature Availability**: 
    - The feature is available to all authenticated users.
    - The user must have the "Memories" setting enabled in their preferences (`memories_enabled`).
    - If disabled, the API returns `403 Forbidden`.
2.  **Fetch Memories**:
    - The client requests `GET /api/v1/memories`.
    - The server calculates "today" based on the user's configured Time Zone.
    - It filters statuses where:
        - `month(created_at) == current_month`
        - `day(created_at) == current_day`
        - `year(created_at) < current_year`
3.  **Display**:
    - Display the returned list of Status objects.
    - If the list is empty, show a "No memories today" state.
    - Use the `Link` header for pagination (infinite scroll).

## API Specification

### GET /api/v1/memories

Retrieves the "Memories" statuses.

**Authentication:**
- Required
- OAuth Scope: `read:statuses`

**Parameters:**

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `max_id` | String | - | Return results older than this ID. |
| `since_id` | String | - | Return results newer than this ID. |
| `min_id` | String | - | Return results immediately newer than this ID. |
| `limit` | Integer | 20 | Number of items per page. Max is usually 40. |

**Headers:**

- `Authorization`: `Bearer <token>`
- `Link`: Pagination links (RFC 5988). Contains `rel="next"` and `rel="prev"` links.

**Response:**

- **Status Code:** `200 OK`
- **Body:** JSON Array of [Status](https://docs.joinmastodon.org/entities/Status/) objects.

**Example Request:**

```http
GET /api/v1/memories?limit=20 HTTP/1.1
Host: mastodon.example.com
Authorization: Bearer XXXXXX
```

**Example Response:**

```json
[
  {
    "id": "10987654321",
    "created_at": "2022-02-13T10:00:00.000Z",
    "in_reply_to_id": null,
    "in_reply_to_account_id": null,
    "sensitive": false,
    "spoiler_text": "",
    "visibility": "public",
    "language": "en",
    "uri": "https://mastodon.example.com/users/user/statuses/10987654321",
    "url": "https://mastodon.example.com/@user/10987654321",
    "replies_count": 0,
    "reblogs_count": 0,
    "favourites_count": 1,
    "edited_at": null,
    "content": "<p>This is a memory from 2022!</p>",
    "reblog": null,
    "account": {
      "id": "12345",
      "username": "user",
      "acct": "user",
      "display_name": "User Name",
      ...
    },
    "media_attachments": [],
    "mentions": [],
    "tags": [],
    "emojis": [],
    "card": null,
    "poll": null
  }
]
```

**Pagination Implementation Note:**

This endpoint supports ID-based pagination (Cursor-based) similar to timelines.
- Use `max_id` to load older posts (next page).
- Use `min_id` to load newer posts (previous page/refresh).
- The `Link` header in the response provides pre-constructed URLs for `next` and `prev`.
