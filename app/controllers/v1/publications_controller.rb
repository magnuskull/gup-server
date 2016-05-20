require 'pp'

class V1::PublicationsController < V1::V1Controller

  api :GET, '/publications/:id', 'Returns a single publication based on pubid.'
  description "Returns a single complete publication object based on pubid. The most recent version of the publication is the one returned."
  def show
    id = params[:id]
    version_id = params[:version_id]
    publication = Publication.find_by_id(id)
    if publication.present? && publication.published_at.nil?
      if !publication.current_version.updated_by.eql?(@current_user.username)
        publication = nil
      end
    end
    if publication.present?
      if(version_id)
        publication_version = publication.publication_versions.where(id: version_id).first
        if(!publication_version)
          error_msg(ErrorCodes::OBJECT_ERROR, "#{I18n.t "publications.errors.not_found"}: #{params[:id]}")
          render_json
          return
        end
      else
        publication_version = publication.current_version
      end
      @response[:publication] = publication.as_json(version: publication_version)
      @response[:publication][:authors] = people_for_publication(publication_version_id: publication_version.id)
      authors_from_import = []
      if @response[:publication][:authors].empty? && publication_version.xml.present? && !publication_version.xml.nil?
        # Do the authorstring
        xml = Nokogiri::XML(publication_version.xml).remove_namespaces!
        datasource = publication_version.datasource
        if datasource.nil?
          # Do nothing
        elsif datasource.eql?("gupea")
          authors_from_import += Gupea.authors(xml)
        elsif  datasource.eql?("pubmed")
          authors_from_import += Pubmed.authors(xml)
        elsif  datasource.eql?("scopus")
          authors_from_import += Scopus.authors(xml)
        elsif  datasource.eql?("scigloo")
          authors_from_import += Scigloo.authors(xml)
        elsif  datasource.eql?("libris")
          authors_from_import += Libris.authors(xml)
        end
      end
      if publication_version.publication_type.blank? && publication_version.xml.present? && !publication_version.xml.nil?
        # Do the authorstring
        xml = Nokogiri::XML(publication_version.xml).remove_namespaces!
        datasource = publication_version.datasource
        if datasource.nil?
          # Do nothing
        elsif datasource.eql?("gupea")
          publication_type_suggestion = Gupea.publication_type_suggestion(xml)
        elsif  datasource.eql?("pubmed")
          publication_type_suggestion = Pubmed.publication_type_suggestion(xml)
        elsif  datasource.eql?("scopus")
          publication_type_suggestion = Scopus.publication_type_suggestion(xml)
        elsif  datasource.eql?("scigloo")
          publication_type_suggestion = Scigloo.publication_type_suggestion(xml)
        elsif  datasource.eql?("libris")
          publication_type_suggestion = Libris.publication_type_suggestion(xml)
        end
      end
      @response[:publication][:authors_from_import] = authors_from_import
      @response[:publication][:publication_type_suggestion] = publication_type_suggestion
    else
      error_msg(ErrorCodes::OBJECT_ERROR, "#{I18n.t "publications.errors.not_found"}: #{params[:id]}")
    end
    render_json
  end

  api :DELETE, '/publications/:pubid'
  desc 'Deletes a given publication based on pubid. Only effective on draft publications.'
  def destroy 
    id = params[:id]
    publication = Publication.find_by_id(id)
    if !publication.present?
      error_msg(ErrorCodes::OBJECT_ERROR, "#{I18n.t "publications.errors.not_found"}: #{params[:id]}")
      render_json
      return
    end
    if publication.published_at && !@current_user.has_right?('delete_published')
      error_msg(ErrorCodes::PERMISSION_ERROR, "#{I18n.t "publications.errors.cannot_delete_published"}")
      render_json
      return
    end
    if publication.update_attribute(:deleted_at, DateTime.now)
      render_json
    else
      error_msg(ErrorCodes::VALIDATION_ERROR,"#{I18n.t "publications.errors.delete_error"}: #{params[:id]}")
      render_json
    end

  end


  private

  def publication_identifier_permitted_params(params)
    params.require(:publication_identifier).permit(:publication_version_id, :identifier_code, :identifier_value)
  end

  def create_publication_identifiers(publication_version: publication_version)
    if params[:publication][:publication_identifiers]
      pis_errors = []
      params[:publication][:publication_identifiers].each do |publication_identifier|
        publication_identifier[:publication_version_id] = publication_version.id
        pi = PublicationIdentifier.new(publication_identifier_permitted_params(ActionController::Parameters.new(publication_identifier: publication_identifier)))
        if !pi.save
          pis_errors << [pi.errors]
        end
      end
      if !pis_errors.empty?
        error_msg(ErrorCodes::OBJECT_ERROR, "#{I18n.t "publication_identifiers.errors.create_error"}", pis_errors)
        error = true
        raise ActiveRecord::Rollback
      end
    end 

  end
  
  # !!! find_current_person moved to app/controllers/concerns/publications_controller_helper.rb

  def find_diff_since_review(publication:, person_id:)
    p2p = People2publication.where(person_id: person_id).where(publication_version_id: publication.current_version_id).first
    if !p2p || p2p.reviewed_publication_version.nil?
      return {}
    else
      # Add diffs from publication object
      diff = publication.current_version.review_diff(p2p.reviewed_publication_version)
      
      # Add diffs from affiliations
      oldp2p = People2publication.where(person_id: person_id).where(publication_version_id: p2p.reviewed_publication_version_id).first

      if oldp2p
        old_affiliations = oldp2p.departments2people2publications.map {|x| x.department_id}
        new_affiliations = p2p.departments2people2publications.map {|x| x.department_id}

        unless (old_affiliations & new_affiliations == old_affiliations) && (new_affiliations & old_affiliations == new_affiliations)
          diff[:affiliation] = {from: Department.where(id: old_affiliations), to: Department.where(id: new_affiliations)}
        end
      end
      
      if diff.blank?
        return {}
      end
      
      diff[:reviewed_at] = oldp2p.reviewed_at
      return diff
    end
  end

  def handle_file_import raw_xml
    if raw_xml.blank?
      error_msg(ErrorCodes::VALIDATION_ERROR, "#{I18n.t "publications.errors.no_data_in_file"}")
      render_json
      return
    end

    xml = Nokogiri::XML(raw_xml)
    if !xml.errors.empty?
      error_msg(ErrorCodes::VALIDATION_ERROR, "#{I18n.t "publications.errors.invalid_file"}", xml.errors)
      render_json
      return
    end

    # check versions
    version_list = xml.search('//source-app').map do |element|
      element.attr("version").to_f
    end
    version_list = version_list.select! do |version|
      version < 8
    end
    if !version_list.empty?
      error_msg(ErrorCodes::VALIDATION_ERROR, "#{I18n.t "publications.errors.unsupported_endnote_version"}")
      render_json
      return
    end

    record_count = 0
    record_total = 0
    return_pub = {}

    xml.search('//xml/records/record').each do |record|
      record_total += 1
      params[:publication] = {}
      endnote = Endnote.parse(record)
      if endnote
        params[:publication].merge!(endnote.as_json)
      else
        params[:publication][:title] = "[Title not found]"
      end

      create_basic_data
      pub = Publication.new(permitted_params(params))
      if pub.save
        record_count += 1
        if record_count == 1
          return_pub = pub
        end
      else
        error_msg(ErrorCodes::VALIDATION_ERROR, "#{I18n.t "publications.errors.update_error"}", pub.errors)
        render_json
        return
      end
    end
    @response[:publication] = return_pub
    @response[:meta] = {result: {count: record_count, total: record_total}}
    render_json(201)
  end

  def import_file
    handle_file_import params[:file].read
  end


  def create_basic_data
    params[:publication][:deleted_at] = nil
    params[:publication][:publication_type] = nil
    params[:publication][:publanguage] ||= 'en'
  end

  def permitted_params(params)
    params.require(:publication).permit(PublicationType.get_all_fields + global_params)
  end

  # Params which are not defined by publication type
  def global_params
    [:publication_type, :is_draft, :is_deleted, :created_at, :created_by, :updated_by, :biblreviewed_at, :biblreviewed_by, :bibl_review_postponed_until, :bibl_review_postpone_comment, :content_type, :xml, :datasource, :sourceid, :category_hsv_local => [], :series => [], :project => []]
  end

  # Creates connections between people, departments and mpublications for a publication and a people array
  def create_affiliation (publication_version_id:, person:, position:, reviewed_at: nil, reviewed_publication_version_id: nil)
    p2p = {person_id: person[:id], position: position, departments2people2publications: person[:departments]}
    p2p_obj = People2publication.create({publication_version_id: publication_version_id, person_id: p2p[:person_id], position: position, reviewed_at: reviewed_at, reviewed_publication_version_id: reviewed_publication_version_id})
    department_list = p2p[:departments2people2publications]
    if department_list.present?
      department_list.each.with_index do |d2p2p, j|
        Departments2people2publication.create({people2publication_id: p2p_obj.id, department_id: d2p2p[:id], position: j + 1})
        # Set affiliated flag to true when a person gets a connection to a department.
        Person.find_by_id(person[:id]).update_attribute(:affiliated, true)
      end
    end
  end

  # Returns collection of people including departments for a specific Publication
  def people_for_publication(publication_version_id:)
    p2ps = People2publication.where(publication_version_id: publication_version_id)
    people = p2ps.map do |p2p|
      person = Person.where(id: p2p.person_id).first.as_json
      department_ids = Departments2people2publication.where(people2publication_id: p2p.id).order(updated_at: :desc).select(:department_id)
      
      departments = Department.where(id: department_ids)
      person['departments'] = departments.as_json

      presentation_string = Person.where(id: p2p.person_id).first.presentation_string(departments.map{|d| I18n.locale == :en ? d.name_en : d.name_sv}.uniq[0..1])
      person['presentation_string'] = presentation_string

      person
    end

    return people
  end

end
