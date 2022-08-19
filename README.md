# AMQPShovel

A high performance AMQP shovel, consuming messages from one server and publishing them to another.

## Installation


## Usage

```sh
amqpshovel \
  --src-uri amqp://user:passwd@downstream-server/vhost \
  --dst-uri amqp://user:passwd@upstream-server/vhost \
  --src-queue my-queue \
  --dst-exchange amq.topic \
  --src-prefetch 1000 \
  --ack-mode on_publish
```

## Contributors

- [84codes](https://www.84codes.com) - main sponsor
- [Carl Hörberg](https://github.com/carlhoerberg) - creator and maintainer
