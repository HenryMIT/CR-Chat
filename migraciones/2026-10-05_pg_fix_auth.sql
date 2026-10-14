-- Corrige: reactivar cuenta sin validar contraseña y filtros de contactos

CREATE OR REPLACE FUNCTION fn_reactive_user(
    p_phone_number VARCHAR,
    p_pass VARCHAR,
    p_key VARCHAR
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    msg INT;
BEGIN 
    IF NOT EXISTS (
        SELECT 1
        FROM usr 
        WHERE (phone_number = p_phone_number OR pgp_sym_decrypt(email, p_key) = p_phone_number)
        AND pgp_sym_decrypt(pass, p_key) = p_pass
        AND deleted = true
    ) THEN 
        RETURN -1;            
    ELSE 
        UPDATE usr SET deleted = false 
        WHERE (phone_number = p_phone_number OR pgp_sym_decrypt(email, p_key) = p_phone_number)
        AND pgp_sym_decrypt(pass, p_key) = p_pass
        RETURNING id_user INTO msg;
        RETURN msg;
    END IF;
END;
$$
SECURITY DEFINER;

CREATE OR REPLACE FUNCTION fn_load_contact(
    p_lim INT,
    p_phone_contact VARCHAR,
    p_contact_name VARCHAR,
    p_id_user INT
)
RETURNS TABLE (
    id_contact INT,
    id_user INT,
    contact_number VARCHAR,
    contact_name VARCHAR,
    deleted BOOLEAN
)
LANGUAGE plpgsql
AS $$
BEGIN
     RETURN QUERY
        SELECT c.id_contact, c.id_user, c.contact_number, c.contact_name, c.deleted
        FROM contact as c
        WHERE c.id_user = p_id_user 
        AND c.deleted = FALSE
        AND (p_phone_contact IS NULL OR c.contact_number ILIKE '%' || p_phone_contact || '%')
        AND (p_contact_name IS NULL OR c.contact_name ILIKE '%' || p_contact_name || '%')
        LIMIT p_lim;  
END;
$$
SECURITY DEFINER;
