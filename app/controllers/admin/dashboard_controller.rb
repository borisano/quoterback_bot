module Admin
  class DashboardController < ApplicationController
    before_action :authenticate!

    def index
      @stats = Admin::StatsQuery.new.call
    end

    private

    def authenticate!
      username = ENV["ADMIN_USERNAME"]
      password = ENV["ADMIN_PASSWORD"]

      if username.blank? || password.blank?
        head :forbidden and return
      end

      authenticate_or_request_with_http_basic("Admin") do |u, p|
        ActiveSupport::SecurityUtils.secure_compare(u, username) &
          ActiveSupport::SecurityUtils.secure_compare(p, password)
      end
    end
  end
end
