# frozen_string_literal: true

require "json"
require "net/http"
require "open-uri"
require "uri"
require "yaml"

module GitHub
  class CoreDataGenerator
    # https://www.analogue.co/developer/docs/core-definition-files/data-json#parameters-bitmap
    # Uncomment a line to add the parameter to the core's API entry.
    BITMAP = {
      # "user_reloadable"   => 0b000000001,
      "core_specific"     => 0b000000010,
      # "nonvolatile"       => 0b000000100,
      # "read_only"         => 0b000001000,
      "instance_json"     => 0b000010000,
      # "init_on_load"      => 0b000100000,
      # "reset_while_load"  => 0b001000000,
      # "reset_around_load" => 0b010000000,
      # "full_reload"       => 0b100000000
    }.freeze

    CACHED_DATA = "_data/cores.yml"
    CORE_FILE   = "core.json"
    DATA_FILE   = "data.json"

    attr_reader :username, :repository, :display_name

    def initialize(username, repository, display_name)
      @username     = username
      @repository   = repository
      @display_name = display_name
    end

    def call
      fetch_releases.each do |release_type, metadata|
        if update_available?(release_type, metadata["tag_name"])
          puts "🟢 Updating #{release_type} data for #{repository} (#{metadata["tag_name"]})."
          @directory = download_asset(metadata["file_name"], metadata["url"])
          json = build_json(release_type, metadata)
          return json unless json.nil?
        else
          puts "🟡 #{repository} (#{metadata["tag_name"]}) is already up-to-date."
          return cached_data
        end
      end
    end

    private

    def fetch_releases
      uri = URI.parse("https://api.github.com/repos/#{username}/#{repository}/releases")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{$github_token}"

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPOK)
        puts "🔴 Something went wrong while fetching the releases for #{repository}."
        exit 1 # Signal to GitHub Actions that the workflow run failed.
      end

      releases = filter_releases(JSON.parse(response.body))

      releases.each.with_object({}) do |release, hash|
        asset = choose_asset(release["assets"])
        key = release["prerelease"] ? "prerelease" : "release"

        hash[key] = {
          "file_name" => asset["name"],
          "url" => asset["url"],
          "tag_name" => release["tag_name"],
          "release_date" => release["published_at"]
        }
      end
    end

    def filter_releases(response_body)
      prerelease = response_body.detect { |release| release["prerelease"] }
      stable = response_body.detect { |release| release["prerelease"] == false }

      return [prerelease] unless stable
      return [stable] unless prerelease
      return [prerelease, stable] if prerelease["id"] > stable["id"]
      [stable]
    end

    # Hack for the openFPGA-GB-GBC repo that hosts cores for both the GB & GBC.
    def choose_asset(assets)
      index = display_name == "Spiritualized GB" ? 1 : 0
      assets[index]
    end

    # We have to use display_name instead of repository here,
    # or else the GBC core will be overwritten with the GB core data on
    # workflow runs where the core has not been updated.
    def cached_data
      @cached_data ||=
        YAML
          .load_file(CACHED_DATA)
          &.detect { |author| author["username"] == username }
          &.dig("cores")
          &.detect { |core| core["display_name"] == display_name }
    end

    def update_available?(release_type, tag_name)
      tag_name != cached_data&.dig(release_type, "tag_name")
    end

    def download_asset(file_name, url)
      dir_name = File.basename(file_name, ".zip")

      # If the directory already exists, don't download it again.
      return dir_name if Dir.exist?(dir_name)

      File.open(file_name, "wb") do |file|
        headers = {
          "Accept" => "application/octet-stream",
          "Authorization" => "Bearer #{$github_token}"
        }
        file << URI.open(url, headers).read
      end
      system("unzip", "-q", file_name, "-d", dir_name)

      dir_name
    end

    def build_json(release_type, repo_metadata)
      core_metadata = parse_json_file(CORE_FILE)&.dig("core", "metadata")

      # Some releases include additional assets on top of the core.
      # If the asset does not include a core.json file, we can safely
      # assume it's not the core and skip it.
      return nil unless core_metadata

      # TODO: Handle multiple platform_ids. No cores currently do this.
      platform_id   = core_metadata["platform_ids"].first
      platform_json = parse_json_file("#{platform_id}.json", "Platforms")["platform"]

      {
        "repository" => repository,
        "display_name" => display_name,
        "identifier" => "#{core_metadata["author"]}.#{core_metadata["shortname"]}",
        "platform" => platform_json["name"], # TODO: Remove this in v2
        release_type => {
          "tag_name" => repo_metadata["tag_name"],
          "release_date" => repo_metadata["release_date"],
          "platform" => platform_json,
          "assets" => build_asset_json(platform_id)
        }
      }
    end

    def build_asset_json(platform)
      data_slots = parse_json_file(DATA_FILE).dig("data", "data_slots")

      data_slots.select { |slot| slot["required"] }.map do |slot|
        { "platform" => platform }.tap do |hash|
          hash["filename"] = slot["filename"] if slot["filename"]
          hash["extensions"] = slot["extensions"] if slot["extensions"]
        end.merge(extract_parameters(slot["parameters"]))
      end.reject { |slot| slot["instance_json"] }
    end

    def parse_json_file(file_name, subdirectory = "Cores")
      file_path = Dir.glob("#{@directory}/#{subdirectory}/**/#{file_name}").first

      # If the file doesn't exist, the directory is not a core.
      return unless file_path

      file = File.read(file_path)
      JSON.parse(file)
    end

    def extract_parameters(int)
      int = int.to_i(16) if int.is_a?(String)

      BITMAP.map.with_object({}) do |(key, val), hash|
        hash[key] = int & val != 0
      end.select { |_, val| val }
    end
  end
end
