# Understanding Rate Limits And Quotas

Rate limits play a crucial role in ensuring fair and reliable access to the API for all users. It's important to note that every API key is subject to two distinct limits — requests per minute and tokens per minute — which work together seamlessly to protect the platform.

## How Rate Limits Work

- **Requests per minute:** This limit caps how many calls a key can make in a 60-second sliding window.
- **Tokens per minute:** This limit caps how many tokens a key can consume in the same window.
- **Team budget:** Additionally, each team has a monthly token budget that serves as an overall ceiling.

When a limit is exceeded, the API returns HTTP `429 Too Many Requests` along with a `retry-after` header, indicating how many seconds to wait before retrying. Every response also includes the `x-ratelimit-remaining-requests` and `x-ratelimit-remaining-tokens` headers, empowering developers to monitor their usage in real time.

## Best Practices For Handling Limits

To navigate rate limits effectively, consider the following:

```bash
curl -i https://api.example-gateway.io/v1/models -H "Authorization: Bearer $API_KEY"
```

Inspect the headers above and implement exponential backoff — starting at 1 second and doubling up to 32 seconds. This approach not only reduces errors but also ensures a smooth experience for your users. For more details, see https://docs.example-gateway.io/limits.

In summary, understanding and respecting rate limits is key to building robust, scalable applications.
