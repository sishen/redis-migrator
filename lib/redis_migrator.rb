require 'rubygems'
require 'redis'
require 'redis/distributed'
require_relative 'redis_migrator/redis_helper'

class Redis
  class Migrator
    include Redis::Helper

    attr_accessor :old_cluster, :new_cluster, :old_hosts, :new_hosts

    def initialize(old_hosts, new_hosts)
      @old_hosts = old_hosts
      @new_hosts = new_hosts
      @old_cluster = Redis::Distributed.new(old_hosts)
      @new_cluster = Redis::Distributed.new(new_hosts)
    end

    def redis
      Thread.current[:redis]
    end

    # Finds redis keys for which migration is needed
    # @return a hash of keys grouped by node they need to be written to
    # @example Returned value
    #   { "redis://host1.com" => ['key1', 'key2', 'key3'],
    #     "redis://host2.com => ['key4', 'key5', 'key6']" }
    def changed_keys
      keys = @old_cluster.keys("*")

      keys.inject({}) do |acc, key|
        old_node = @old_cluster.node_for(key).client
        new_node = @new_cluster.node_for(key).client

        if (old_node.host != new_node.host) || (old_node.port != new_node.port)
          hash_key = "redis://#{new_node.host}:#{new_node.port}/#{new_node.db}"
          acc[hash_key] = [] if acc[hash_key].nil?
          acc[hash_key] << key
        end

        acc
      end
    end

    # Migrates a given array of keys to a given redis node
    # @param node [Hash] options for redis node keys will be migrated to
    # @param keys [Array] array of keys that need to be migrated
    # @param options [Hash] additional options, such as :do_not_remove => true
    def migrate_keys(node, keys, options={})
      return false if keys.empty? || keys.nil?
      
      Thread.current[:redis] = Redis::Distributed.new(old_hosts)

      pipe = IO.popen("redis-cli -h #{node[:host]} -p #{node[:port]} -n #{node[:db]} --pipe", IO::RDWR)

      keys.each {|key|
        copy_key(pipe, key)

        #remove key from old node
        redis.node_for(key).del(key) unless options[:do_not_remove]
      }

      pipe.close
    end

    # Runs a migration process for a Redis cluster. 
    # @param [Hash] additional options such as :do_not_remove => true
    def run(options={})
      keys_to_migrate = changed_keys
      puts "Migrating #{keys_to_migrate.values.flatten.count} keys"
      threads = []

      keys_to_migrate.keys.each do |node_url|
        node = parse_redis_url(node_url)
        
        #spawn a separate thread for each Redis pipe
        threads << Thread.new(node, keys_to_migrate[node_url]) {|node, keys|
          migrate_keys(node, keys, options)
        }
      end

      threads.each{|t| t.join}
    end

    # Copy a given Redis key to a Redis pipe
    # @param pipe [IO] a pipe opened  redis-cli --pipe 
    # @param key [String] a Redis key that needs to be copied
    def copy_key(pipe, key)
      key_type = old_cluster.type(key)
      return false unless ['list', 'hash', 'string', 'set', 'zset'].include?(key_type)

      self.send("copy_#{key_type}", pipe, key)
    end

  end # class Migrator
end # class Redis
