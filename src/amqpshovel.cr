require "option_parser"
require "amqp-client"

class AMQPShovel
  VERSION = "0.1.0"

  @pub_channel = Channel(AMQP::Client::DeliverMessage).new
  @done_channel = Channel(UInt64).new
  @unacked_count = 0

  @dst_uri = "amqp://localhost"
  @dst_exchange : String? = nil
  @dst_routing_key : String? = nil

  @src_uri = "amqp://localhost"
  @src_queue = ""
  @src_exchange = "amq.topic"
  @src_binding_key = "#"

  @prefetch_count = 1000
  @ack_mode = AckMode::OnPublish

  def initialize
    parse_argv
  end

  def start
    puts "AMQPShovel #{VERSION}"
    puts "Source URI: #{URI.parse(@src_uri).tap(&.password = ".")}"
    if @src_queue.empty?
      puts "Source exchange: #{@src_exchange}"
      puts "Source binding key: #{@src_binding_key}"
    else
      puts "Source queue: #{@src_queue}"
    end
    puts "Destination URI: #{URI.parse(@dst_uri).tap(&.password = "")}"
    puts "Destination exchange: #{@dst_exchange}" if @dst_exchange
    puts "Destination routing_key key: #{@dst_routing_key}" if @dst_routing_key
    puts "Prefetch: #{@prefetch_count}"
    puts "Ack-mode: #{@ack_mode}"
    spawn publish_loop
    spawn consume_loop
  end

  def consume_loop
    loop do
      AMQP::Client.start(@src_uri + "?name=AMQPShovel consumer") do |conn|
        ch = conn.channel
        ch.prefetch(@prefetch_count)
        if @src_queue.empty?
          q = ch.queue
          q.bind(@src_exchange, @src_binding_key)
        else
          q = ch.queue(@src_queue, passive: true)
        end
        no_ack = @ack_mode.no_ack?
        q.subscribe(tag: "a", no_ack: no_ack, block: no_ack) do |msg|
          @unacked_count += 1 unless no_ack
          @pub_channel.send(msg)
        end

        ack_loop(ch)
      end
    rescue ex : AMQP::Client::Error
      puts "consumer: #{ex.message}"
      sleep 5
    end
  end

  # Multi ack consumed msgs when half the prefetch is used up
  # or after 1s of no confirms coming from the destination
  def ack_loop(ch)
    last_published_delivery_tag = 0u64
    loop do
      select
      when delivery_tag = @done_channel.receive
        last_published_delivery_tag = delivery_tag
        if @unacked_count >= @prefetch_count // 2
          ch.basic_ack(delivery_tag, multiple: true)
          @unacked_count = 0
        end
      when timeout 1.second
        if @unacked_count > 0 && last_published_delivery_tag > 0
          ch.basic_ack(last_published_delivery_tag, multiple: true)
          @unacked_count = 0
        end
      end
    end
  end

  def publish_loop
    loop do
      AMQP::Client.start(@dst_uri + "?name=AMQPShovel publisher") do |conn|
        ch = conn.channel
        ack_mode = @ack_mode
        ex = @dst_exchange
        rk = @dst_routing_key
        done = @done_channel
        ch.confirm_select if ack_mode.on_confirm?
        while msg = @pub_channel.receive?
          id = ch.basic_publish(msg.body_io, exchange: ex || msg.exchange, routing_key: rk || msg.routing_key, props: msg.properties)
          case ack_mode
          in .no_ack? then next
          in .on_publish?
            done.send(msg.delivery_tag)
          in .on_confirm?
            ch.on_confirm(id) do |_ok|
              done.send(msg.delivery_tag)
            end
          end
        end
      end
    rescue ex : AMQP::Client::Error
      puts "publisher: #{ex.message}"
      sleep 5
    end
  end

  def parse_argv
    OptionParser.parse do |parser|
      parser.banner = "Usage: amqpshovel --src-uri URI --dst-uri URI --src-queue/--src-exchange [--src-routing-key]"
      parser.on("--src-uri=URI", "Source URI") { |v| @src_uri = v }
      parser.on("--src-exchange=NAME", "Exchange to consume from") { |v| @src_exchange = v }
      parser.on("--src-binding-key=KEY", "Binding key to use when consuming from an exchange") { |v| @src_binding_key = v }
      parser.on("--src-queue=NAME", "Queue to consume from (must exist, overrides --src-exchange)") { |v| @src_queue = v }
      parser.on("--src-prefetch=LIMIT", "Prefetch limit") { |v| @prefetch_count = v.to_i }
      parser.on("--ack-mode=MODE", "Ack mode, noack, on-publish or on-confirm") { |v| @ack_mode = AckMode.parse(v) }

      parser.on("--dst-uri=URI", "Destination URI") { |v| @dst_uri = v }
      parser.on("--dst-exchange=NAME", "Publish to exchange") { |v| @dst_exchange = v }
      parser.on("--dst-routing-key=KEY", "Optionally override the routing key when shovling to an exchange") { |v| @dst_routing_key = v }
      parser.on("--dst-queue=NAME", "Publish to a queue (overrides --dst-exchange)") { |v| @dst_exchange = ""; @dst_routing_key = v }

      parser.on("-h", "--help", "Show this help") do
        puts parser
        exit
      end
      parser.invalid_option do |flag|
        STDERR.puts "ERROR: #{flag} is not a valid option."
        STDERR.puts parser
        exit 1
      end
    end
  end

  enum AckMode
    NoAck
    OnPublish
    OnConfirm
  end
end

AMQPShovel.new.start
sleep
