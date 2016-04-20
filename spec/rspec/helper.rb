# ----------------------------------------------------------------------------
# Frozen-string-literal: true
# Copyright: 2015 Jordon Bedwell - MIT License
# Encoding: utf-8
# ----------------------------------------------------------------------------

require "rspec"
require "support/coverage"
require "luna/rspec/formatters/checks"
require "jekyll/assets"
require "stackprof"
require "jekyll"

StackProf.start(mode: :cpu, out: 'stackprof.dump')
Dir[File.expand_path("../../support/*.rb", __FILE__)].each do |v|
  require v
end

at_exit do
  StackProf.tap(&:stop).results
end
