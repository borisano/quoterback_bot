Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Telegram webhook endpoint (used in production; dev uses long-polling).
  post "telegram/webhook" => "telegram_webhooks#create"

  # Admin dashboard (HTTP Basic Auth required).
  namespace :admin do
    get "dashboard" => "dashboard#index", as: :dashboard
    root to: "dashboard#index"
  end
end
