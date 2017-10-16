# Frozen-string-literal: true
# Copyright: 2012 - 2017 - MIT License
# Encoding: utf-8

require "pathutil"
require "forwardable/extended"
require "jekyll/sanity"
require "sprockets"
require "jekyll"

require_all "patches/*"
require_relative "drop"
require_relative "cached"
require_relative "manifest"
require_relative "helpers"
require_relative "config"
require_relative "logger"
require_relative "hook"
require_relative "tag"

module Jekyll
  module Assets
    class Env < Sprockets::Environment
      extend Forwardable::Extended
      rb_delegate :logger, to: :"Jekyll::Assets::Logger"
      attr_accessor :jekyll

      def uncached
        self
      end

      def initialize(jekyll = nil)
        super()

        @jekyll = jekyll
        jekyll.sprockets = self
        @cache = nil

        excludes!
        disable_erb!
        enable_compression!
        setup_sources!
        setup_drops!
        precompile!

        Hook.trigger :env, :init do |hook|
          instance_eval(&hook)
        end
      end

      def find_asset!(file, *args)
        file.is_a?(Sprockets::Asset) ? super(file.logical_path,
          *args) : super
      end

      def find_asset_source!(asset)
        unless asset.is_a?(Sprockets::Asset)
          asset = find_asset!(asset)
        end

        source_logical_path = Pathname.new(asset.logical_path)
        source_logical_path = source_logical_path.sub_ext(".source#{source_logical_path.extname}")
        find_asset!(source_logical_path)
      end

      def skip_gzip?
        !asset_config[:compression]
      end

      # TODO: Needs to move to `Manifest`
      def compile(name)
        other = get_name(name)
        asset = find_asset(other)
        didit = manifest.compile(other) if asset
        asset = find_asset!(name) if !didit
        didit = manifest.compile(name) \
          if !didit

        if didit.size > 0
          Hook.trigger :asset, :compile do |h|
            h.call(asset, manifest)
          end
        end
      end

      def cache
        @cache ||= begin
          type = asset_config[:caching][:type]
          enabled = asset_config[:caching][:enabled]
          path = in_cache_dir

          out = Sprockets::Cache::MemoryStore.new if enabled && type == "memory"
          out = Sprockets::Cache::FileStore.new(path) if enabled && type == "file"
          out = Sprockets::Cache::NullStore.new if !enabled
          Sprockets::Cache.new(out, Logger)
        end
      end

      def asset_config
        @asset_config ||= begin
          user = jekyll.config["assets"] ||= {}
          Config.new(user)
        end
      end

      def manifest
        @manifest ||= begin
          Manifest.new(self, in_dest_dir)
        end
      end

      def to_liquid_payload
        each_file.each_with_object({}) do |k, h|
          path = strip_paths(k)
          next if File.basename(path).start_with?("_") ||
                  File. dirname(path).start_with?("_")

          h.update({
            path => Drop.new(path, {
              jekyll: jekyll
            })
          })
        end
      end

      # TODO: This needs to move to `Cache`
      def in_cache_dir(*paths)
        cache_path = jekyll.in_source_dir(asset_config[:caching][:path])
        paths.reduce(cache_path) do |b, p|
          Jekyll.sanitized_path(b, p)
        end
      end

      def in_dest_dir(*paths)
        jekyll.in_dest_dir(prefix_path, *paths)
      end

      # TODO: Remove
      def cdn?
        !dev? && asset_config[:cdn].key?(:url) &&
              asset_config[:cdn][:url]
      end

      def baseurl
        ary = []
        s1, s2 = asset_config[:cdn].values_at(:baseurl, :prefix)
        ary << jekyll.config["baseurl"] unless cdn? && !s1
        ary <<  asset_config[:prefix  ] unless cdn? && !s2
        File.join(*ary.delete_if do |val|
          val.nil? || val.empty?
        end)
      end

      def prefix_path(path = nil)
        path_ = []

        path_ << baseurl unless baseurl.empty?
        unless path.nil?
          path_ << path
        end

        url = asset_config[:cdn][:url] && cdn??
          File.join(asset_config[:cdn][:url], *path_) :
          File.join(*path_)

        url.chomp("/")
      end

      def cached
        @cached ||= Cached.new(self)
      end

      def self.register_ext_map(ext, to_ext)
        @ext_maps ||= {}
        @ext_maps.update({
          ext.to_s => to_ext.to_s
        })
      end

      def self.map_ext(ext)
        @ext_maps[ext] || ext
      end

      def get_name(file)
        out = Pathutil.new(strip_paths(file))
        extension = self.class.map_ext(out.extname)
        out.sub_ext(extension).to_s
      end

      def in_source_dir(path)
        Pathutil.new(jekyll.in_source_dir(path))
      end

      def strip_paths(path)
        paths.map do |v|
          if path.start_with?(v)
            return path.sub(v + "/", "")
          end
        end

        path
      end

      private
      def excludes!
        excludes = Config.defaults[:sources]
        @jekyll.config["exclude"].push(excludes)
        @jekyll.config["exclude"].uniq!
      end

      private
      def enable_compression!
        if asset_config[:compression]
          if Jekyll.production?
            self.js_compressor, self.css_compressor =
              :uglify, :sass
          else
            self.js_compressor, self.css_compressor =
              :source_map, :source_map
          end
        end
        nil
      end

      private
      def precompile!
        assets = asset_config[:precompile]
        assets = assets.map do |v|
          compile(v)
        end

        nil
      end

      private
      def disable_erb!
        if jekyll.safe
          @config = hash_reassoc @config, :registered_transformers do |o|
            o.delete_if do |v|
              v.proc == Sprockets::ERBProcessor
            end
          end
        end
      end

      private
      def setup_sources!
        @sources ||= begin
          asset_config["sources"].each do |v|
            unless paths.include?(jekyll.in_source_dir(v))
              append_path jekyll.in_source_dir(v)
            end
          end

          paths
        end
      end

      private
      def setup_drops!
        Jekyll::Hooks.register :site, :pre_render do |o, h|
          h["assets"] = to_liquid_payload
        end
      end

      register_ext_map ".es6", ".js"
      register_ext_map ".coffee", ".js"
      register_ext_map ".js.coffee",".js"
      register_ext_map ".js.coffee.erb", ".js"
      register_ext_map ".coffee.erb", ".js"
      register_ext_map ".es6.erb", ".js"
      register_ext_map ".js.erb", ".js"

      register_ext_map ".sass", ".css"
      register_ext_map ".scss", ".css"
      register_ext_map ".css.scss", ".css"
      register_ext_map ".css.scss.erb", ".css"
      register_ext_map ".css.sass.erb", ".css"
      register_ext_map ".sass.erb", ".css"
      register_ext_map ".css.sass", ".css"
      register_ext_map ".scss.erb", ".css"
      register_ext_map ".css.erb", ".css"
      require_all "plugins/*"
    end
  end
end
