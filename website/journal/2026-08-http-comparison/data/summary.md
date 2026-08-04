# HTTP comparison summary

Medians are across complete trials; raw oha JSON remains in `runs/`.

| Server | Workload | c | Connections | Trials | req/s | p50 ms | p99 ms | p99.9 ms |
| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| aws | plaintext | 1 | keepalive | 3 | 18494.8 | 0.057 | 0.085 | 0.137 |
| aws | plaintext | 8 | keepalive | 3 | 44822.7 | 0.177 | 0.300 | 0.399 |
| aws | plaintext | 32 | keepalive | 3 | 30551.7 | 1.009 | 1.326 | 3.431 |
| aws | response-1k | 1 | keepalive | 3 | 15182.5 | 0.067 | 0.088 | 0.136 |
| aws | response-1k | 8 | keepalive | 3 | 42909.2 | 0.175 | 0.322 | 0.427 |
| aws | response-1k | 32 | keepalive | 3 | 29861.3 | 1.079 | 1.372 | 1.879 |
| ews | plaintext | 1 | keepalive | 3 | 15207.5 | 0.066 | 0.080 | 0.132 |
| ews | plaintext | 8 | keepalive | 3 | 27767.1 | 0.072 | 0.092 | 20.749 |
| ews | plaintext | 32 | keepalive | 3 | 28816.1 | 0.071 | 0.085 | 77.476 |
| ews | response-1k | 1 | keepalive | 3 | 16188.8 | 0.061 | 0.079 | 0.126 |
| ews | response-1k | 8 | keepalive | 3 | 28223.7 | 0.072 | 0.088 | 9.313 |
| ews | response-1k | 32 | keepalive | 3 | 26697.8 | 0.073 | 0.093 | 79.006 |
| flyology-app-lightweight | routed-get | 1 | keepalive | 3 | 19220.7 | 0.051 | 0.067 | 0.252 |
| flyology-app-lightweight | routed-get | 8 | keepalive | 3 | 53901.6 | 0.144 | 0.346 | 0.664 |
| flyology-app-lightweight | routed-get | 32 | keepalive | 3 | 52643.2 | 0.604 | 0.817 | 1.245 |
| flyology-app-native | routed-get | 1 | keepalive | 3 | 22278.4 | 0.048 | 0.069 | 0.332 |
| flyology-app-native | routed-get | 8 | keepalive | 3 | 140493.2 | 0.056 | 0.123 | 0.359 |
| flyology-app-native | routed-get | 32 | keepalive | 3 | 350433.2 | 0.077 | 0.325 | 0.628 |
| flyology-lightweight | plaintext | 1 | keepalive | 3 | 19593.8 | 0.047 | 0.065 | 0.275 |
| flyology-lightweight | plaintext | 8 | keepalive | 3 | 64885.6 | 0.120 | 0.209 | 0.448 |
| flyology-lightweight | plaintext | 32 | keepalive | 3 | 68458.6 | 0.462 | 0.633 | 0.979 |
| flyology-lightweight | response-1k | 1 | keepalive | 3 | 20768.3 | 0.049 | 0.064 | 0.260 |
| flyology-lightweight | response-1k | 8 | keepalive | 3 | 65485.6 | 0.119 | 0.180 | 0.453 |
| flyology-lightweight | response-1k | 32 | keepalive | 3 | 63692.5 | 0.496 | 0.640 | 1.072 |
| flyology-native | plaintext | 1 | keepalive | 3 | 39208.1 | 0.023 | 0.053 | 0.277 |
| flyology-native | plaintext | 8 | keepalive | 3 | 239858.1 | 0.019 | 0.098 | 0.353 |
| flyology-native | plaintext | 32 | keepalive | 3 | 383993.7 | 0.071 | 0.312 | 0.606 |
| flyology-native | response-1k | 1 | keepalive | 3 | 25216.8 | 0.044 | 0.057 | 0.257 |
| flyology-native | response-1k | 8 | keepalive | 3 | 161490.7 | 0.050 | 0.113 | 0.349 |
| flyology-native | response-1k | 32 | keepalive | 3 | 373935.1 | 0.072 | 0.305 | 0.584 |
| servletada-aws | routed-get | 1 | keepalive | 3 | 10027.6 | 0.102 | 0.134 | 0.228 |
| servletada-aws | routed-get | 8 | keepalive | 3 | 34107.6 | 0.218 | 0.517 | 0.692 |
| servletada-aws | routed-get | 32 | keepalive | 3 | 17513.6 | 1.874 | 2.759 | 5.615 |
| servletada-ews | routed-get | 1 | keepalive | 3 | 14755.4 | 0.068 | 0.082 | 0.113 |
| servletada-ews | routed-get | 8 | keepalive | 3 | 24296.9 | 0.082 | 0.113 | 16.881 |
| servletada-ews | routed-get | 32 | keepalive | 3 | 24708.2 | 0.079 | 0.106 | 80.241 |

## Process resources

Samples cover all warmups and workloads for that server in a trial. Compare servers only within the same tier.

| Server | Trials | CPU s | Max RSS MiB | Max threads |
| --- | ---: | ---: | ---: | ---: |
| aws | 3 | 25.64 | 24.8 | 258 |
| ews | 3 | 17.89 | 2.1 | 2 |
| flyology-app-lightweight | 3 | 8.68 | 10.4 | 2 |
| flyology-app-native | 3 | 47.19 | 13.9 | 257 |
| flyology-lightweight | 3 | 17.25 | 10.1 | 2 |
| flyology-native | 3 | 91.50 | 12.8 | 257 |
| servletada-aws | 3 | 19.33 | 30.0 | 258 |
| servletada-ews | 3 | 8.98 | 4.7 | 2 |
