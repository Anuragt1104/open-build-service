class BinaryRelease < ActiveRecord::Base
  #### Includes and extends
  #### Constants
  #### Self config
  class SaveError < APIException; end

  #### Attributes
  #### Associations macros (Belongs to, Has one, Has many)
  belongs_to :repository
  belongs_to :release_package, :class_name => "Package", foreign_key: "release_package_id" # optional

  #### Callbacks macros: before_save, after_save, etc.
  before_create :set_release_time
  after_rollback :reset_cache
  after_save :reset_cache

  #### Scopes (first the default_scope macro if is used)


  #### Validations macros
  #### Class methods using self. (public and then private)
  def self.update_binary_releases(repository, key, time = Time.now)
    begin
      body = Suse::Backend.get("/notificationpayload/#{key}").body
      pt = ActiveSupport::JSON.decode(body)
    rescue ActiveXML::Transport::NotFoundError
      logger.error("Payload got removed for #{key}")
      return
    end
    update_binary_releases_via_json(repository, pt, time)
    # drop it
    Suse::Backend.delete("/notificationpayload/#{key}")
  end

  def self.update_binary_releases_via_json(repository, json, time = Time.now)
    oldlist = where(repository: repository, obsolete_time: nil)
    processed_item = {} # we can not just remove it from relation
                        # delete would affect the object

    BinaryRelease.transaction do
      json.each do |binary|
        # identifier
        hash = { binary_name:    binary["name"],
                 binary_version: binary["version"],
                 binary_release: binary["release"],
                 binary_epoch:   binary["epoch"],
                 binary_arch:    binary["binaryarch"],
                 medium:         binary["medium"],
                 obsolete_time:  nil
             }
        # check for existing entry
        existing = oldlist.where(hash)
        Rails.logger.info "ERROR: multiple matches, cleaning up: #{existing.inspect}" if existing.count > 1
        # double definition means broken DB entries
        existing.offset(1).destroy_all

        # compare with existing entry
        if existing.count == 1
          entry = existing.first
          if entry.binary_disturl                   == binary["disturl"] and
             entry.binary_supportstatus             == binary["supportstatus"] and
             entry.binary_buildtime.to_datetime.utc == ::Time.at(binary["buildtime"].to_i).to_datetime.utc
             # same binary, don't touch
             processed_item[entry.id] = true
             next
          end
          # same binary name and location, but different content
          entry.obsolete_time = time
          entry.save!
          processed_item[entry.id] = true
          hash[:operation] = "modified" # new entry will get "modified" instead of "added"
        end

        # complete hash for new entry
        hash[:binary_releasetime] = time
        hash[:binary_buildtime] = nil
        hash[:binary_buildtime] = ::Time.at(binary["buildtime"].to_i).to_datetime if binary["buildtime"].to_i > 0
        hash[:binary_disturl] = binary["disturl"]
        hash[:binary_supportstatus] = binary["supportstatus"]
        if binary["updateinfoid"]
          hash[:binary_updateinfo] = binary["updateinfoid"]
          hash[:binary_updateinfo_version] = binary["updateinfoversion"]
        end
        if binary["project"] and rp = Package.find_by_project_and_name(binary["project"], binary["package"])
          hash[:release_package_id] = rp.id
        end
        if binary["patchinforef"]
          begin
            pi = Patchinfo.new(Suse::Backend.get("/source/#{binary["patchinforef"]}/_patchinfo").body)
          rescue ActiveXML::Transport::NotFoundError
            # patchinfo disappeared meanwhile
          end
          # no database object on purpose, since it must also work for historic releases...
          hash[:binary_maintainer] = pi.to_hash['packager'] if pi and pi.to_hash['packager']
        end

        # new entry, also for modified binaries.
        entry = repository.binary_releases.create(hash)
        processed_item[entry.id] = true
      end

      # and mark all not processed binaries as removed
      oldlist.each do |e|
        next if processed_item[e.id]
        e.obsolete_time = time
        e.save!
      end
    end
  end

  #### To define class methods as private use private_class_method
  #### private
  #### Instance methods (public and then protected/private)
  def set_release_time!
    self.binary_releasetime = Time.now
  end

  def set_release_time
    # created_at, but readable in database
    self.binary_releasetime ||= Time.now
  end

  def update_for_product
    repository.product_update_repositories.map{ |i| i.product if i.product }
  end

  def product_medium
    repository.product_medium.where(name: medium).first
  end

  # renders all values, which are used as identifier of a binary entry.
  def render_attributes
    attributes = { project: repository.project.name, repository: repository.name }
    [:binary_name, :binary_epoch, :binary_version, :binary_release, :binary_arch, :medium].each do |key|
      value = self.send(key)
      next unless value
      ekey = key.to_s.gsub(/^binary_/, '')
      attributes[ekey] = value
    end
    attributes
  end

  def render_xml
    builder = Nokogiri::XML::Builder.new
    builder.binary(render_attributes) do |binary|
      binary.operation self.operation

      node={}
      node[:package] = self.release_package.name if self.release_package
      node[:time] = self.binary_releasetime if self.binary_releasetime
      binary.publish(node) if node.length > 0

      binary.build(:time => self.binary_buildtime) if self.binary_buildtime

      binary.obsolete(:time => self.obsolete_time) if self.obsolete_time

      binary.supportstatus self.binary_supportstatus if self.binary_supportstatus
      binary.updateinfo({:id      => self.binary_updateinfo,
                         :version => self.binary_updateinfo_version}) if self.binary_updateinfo
      binary.maintainer self.binary_maintainer if self.binary_maintainer
      binary.disturl self.binary_disturl if self.binary_disturl

      update_for_product.uniq.each do |up|
        binary.updatefor( up.extend_id_hash({project: up.package.project.name, product: up.name}) )
      end

      if self.product_medium
        binary.product( product_medium.product.extend_id_hash({name: self.product_medium.product.name}) )
      end

    end
    builder.to_xml :save_with => Nokogiri::XML::Node::SaveOptions::NO_DECLARATION |
                                 Nokogiri::XML::Node::SaveOptions::FORMAT
  end

  def to_axml_id
    builder = Nokogiri::XML::Builder.new
    builder.binary(render_attributes)
    builder.to_xml :save_with => Nokogiri::XML::Node::SaveOptions::NO_DECLARATION |
                                 Nokogiri::XML::Node::SaveOptions::FORMAT
  end

  def to_axml(opts={})
    Rails.cache.fetch('xml_binary_release_%d' % id) { render_xml }
  end

  def reset_cache
    Rails.cache.delete('xml_binary_release_%d' % id)
  end

  #### Alias of methods

end
